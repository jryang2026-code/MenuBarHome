import { discoverMiHome } from "./miCloud/discovery.js";
import { PowerReadBackError, type ExecuteOptions, type HomeProvider } from "./homeProvider.js";
import { readMiotPower } from "./models.js";
import { tr3, type LanguagePreference } from "./i18n.js";
import { MI_SESSION_WARNING_LEAD_MS,
  miSessionExpiryState,
} from "./miCloud/session.js";
import { parseMiotActionAddress,
  parseMiotAddress,
} from "./miCloud/spec.js";
import { MiCloudClient,
  MiCloudError,
  MiotCommandMapper,
  MiotSpecResolver,
  MiotSynthesizer,
  maskedMiUserId,
  miCloudRegionLabel,
  normalizeMiCloudRegion,
  propKeyString,
  type HttpTransport,
  type MiDeviceRecord,
  type MiRoom,
  type MiSession,
  type MiotDeviceSpec,
  type MiotPropKey,
} from "./miCloudClient.js";
import { environmentReadingPriority,
  type ConnectionStatus,
  type DeviceCommand,
  type EnvironmentReading,
  type FacetControl,
  type HomeScene,
  type RoomCategory,
  type SmartDevice,
  type SynthesizedHome,
} from "./models.js";
import { buildMiotTypePrunePlan, miotRoundClosesCategory } from "./miotTypePruning.js";
import type { CapabilityIndexedDevice, CapabilitySelection, SafetySignalKind } from "./capabilityReferenceVerdict.js";
import { clearPersistedMiSessionExpired,
  clearPersistedMiSessionExpiredFor,
  defaultStorage,
  isXiaomiRateLimitError,
  MI_ACCOUNTS_EXPIRED_STORAGE_KEY,
  miAccountId,
  miSessionFingerprint,
  miSessionRejectedRecord,
  persistMiSessionExpired,
  PollingPolicy,
} from "./pollingPolicy.js";
import { CredentialVault,
  WIN32_CRED_MAX_BLOB_BYTES,
  assertCredentialBlobWithinLimit,
  normalizeMiCredentialSlotId,
  parseMiSession,
  serializeMiSession,
  sessionWithoutPassToken,
} from "./secureStore.js";

export const MI_ACCOUNTS_INDEX_STORAGE_KEY = "menumijia.windows.miAccountsIndex.v1";
// Re-exported for existing imports; the rejection store itself lives in `pollingPolicy.ts`.
export { MI_ACCOUNTS_EXPIRED_STORAGE_KEY, miAccountId };

function miAccountSlotId(accountIdOrSession: string | Pick<MiSession, "userId" | "region">,
): string { const id = typeof accountIdOrSession === "string"
      ? accountIdOrSession
      : miAccountId(accountIdOrSession);
  return normalizeMiCredentialSlotId(id);
}

export interface MiAccount { readonly id: string;
  readonly slotId: string;
  readonly region: string;
  readonly regionLabel: string;
  readonly maskedUserId: string;
  readonly displayName: string;
  readonly session: MiSession;
}

export function makeMiAccount(rawSession: MiSession): MiAccount { const clean = sessionWithoutPassToken(rawSession);
  const region = normalizeMiCloudRegion(clean.region);
  const normalizedSession: MiSession = clean.region === region ? clean : { ...clean, region };
  const id = miAccountId(normalizedSession);
  const slotId = miAccountSlotId(id);
  const masked = maskedMiUserId(normalizedSession.userId.trim());
  const regionLabel = miCloudRegionLabel(region);
  return {
    id,
    slotId,
    region,
    regionLabel,
    maskedUserId: masked,
    displayName: `${masked} · ${regionLabel}`,
    session: normalizedSession,
  };
}

export const MiAccountScope = {
  OTHER_ACCOUNT_HOME_SENTINEL: "__other_account_home__",

  id(localId: string, accountId: string): string { return `${accountId}/${localId}`;
  },

  owner(scopedId: string): string | null { const slash = scopedId.indexOf("/");
    return slash >= 0 ? scopedId.slice(0, slash) : null;
  },

  localId(scopedId: string): string { const slash = scopedId.indexOf("/");
    return slash >= 0 ? scopedId.slice(slash + 1) : scopedId;
  },

  isOwned(scopedId: string, accountId: string): boolean { return scopedId.startsWith(`${accountId}/`);
  },

    scopedSelectionForAccount(selectedHomeId: string | null | undefined,
    accountId: string,
    allAccountIds: readonly string[],
  ): string | null { if (!selectedHomeId || selectedHomeId.trim() === "") return null;
    const ownerId = MiAccountScope.owner(selectedHomeId);
    if (ownerId === null) { if (allAccountIds[0] === accountId) return selectedHomeId;
      return allAccountIds.length > 1 ? MiAccountScope.OTHER_ACCOUNT_HOME_SENTINEL : null;
    }
    if (ownerId !== accountId) {
      return allAccountIds.includes(ownerId) ? MiAccountScope.OTHER_ACCOUNT_HOME_SENTINEL : null;
    }
    const raw = MiAccountScope.localId(selectedHomeId);
    return raw === "" ? null : raw;
  },
} as const;

export type MiAccountTokenStatus = | { readonly kind: "valid" }
  | { readonly kind: "expiringSoon"; readonly expiresAtMs: number }
  | { readonly kind: "expired";
      readonly source: "cookie" | "rejected";
      readonly expiredAtMs?: number;
    };

/**
 * Records a server rejection (or clears it) for one session. Both modes are per-fingerprint key
 * writes, so they never read-modify-write a shared object and cannot drop another window's record.
 * `isPrimary` is accepted for call-site compatibility; per-key storage no longer needs it.
 */
export function markAccountSessionRejected(session: MiSession | null | undefined,
  expired: boolean,
  options: { readonly isPrimary?: boolean;
    readonly storage?: Storage | null;
    readonly nowMs?: number;
  } = {},
): void { if (!session) return;
  const storage = options.storage !== undefined ? options.storage : defaultStorage();
  persistMiSessionExpired(session, expired, storage, options.nowMs ?? Date.now());
}

export function getAccountTokenStatus(accountOrSession: MiAccount | MiSession,
  nowMs = Date.now(),
  storage: Storage | null = defaultStorage(),
  warningLeadMs = MI_SESSION_WARNING_LEAD_MS,
): MiAccountTokenStatus { const session = "session" in accountOrSession ? accountOrSession.session : accountOrSession;
  const rejection = miSessionRejectedRecord(session, storage);
  if (rejection) { return {
      kind: "expired",
      source: "rejected",
      expiredAtMs: rejection.expiredAtMs,
    };
  }
  const effectiveExpiresAt = typeof session.expiresAt === "number" && Number.isFinite(session.expiresAt)
      ? session.expiresAt
      : (() => { const match = /(?:^|;\s*)Expires=([^;]+)/i.exec(session.serviceToken);
          const parsed = match?.[1] ? Date.parse(match[1].trim()) : Number.NaN;
          return Number.isFinite(parsed) ? parsed : undefined;
        })();
  const sessionWithExpiry = effectiveExpiresAt !== undefined && session.expiresAt === undefined
      ? { ...session, expiresAt: effectiveExpiresAt }
      : session;
  const cookieState = miSessionExpiryState(sessionWithExpiry, nowMs, warningLeadMs);
  if (cookieState.kind === "expired") { return {
      kind: "expired",
      source: "cookie",
      ...(typeof effectiveExpiresAt === "number" ? { expiredAtMs: effectiveExpiresAt } : {}),
    };
  }
  if (cookieState.kind === "expiringSoon") { return { kind: "expiringSoon", expiresAtMs: cookieState.expiresAtMs };
  }
  return { kind: "valid" };
}

export function formatAccountTokenNotice(account: MiAccount,
  status: MiAccountTokenStatus,
  preference?: LanguagePreference,
): string | null { if (status.kind === "valid") return null;
  if (status.kind === "expired") { return tr3("小米账号 {account} 登录已失效，请重新扫码登录",
      "小米帳號 {account} 登入已失效，請重新掃碼登入",
      "Xiaomi account {account} sign-in has expired; please scan QR code again",
      { account: account.displayName },
      preference,
    );
  }
  const dateStr = new Date(status.expiresAtMs).toISOString().slice(0, 10);
  return tr3("小米账号 {account} 登录将在 {date} 到期",
    "小米帳號 {account} 登入將在 {date} 到期",
    "Xiaomi account {account} sign-in expires on {date}",
    { account: account.displayName, date: dateStr },
    preference,
  );
}

interface MiAccountIndexEntry { readonly id: string;
  readonly slotId: string;
  readonly region: string;
  readonly maskedUserId: string;
}

export type MiAccountIndexStatus = "missing" | "ok" | "corrupt";

export interface MiAccountIndexSnapshot {
  /** `missing`: no stored index. `ok`: parsed, with any unusable entry skipped. `corrupt`: exists but unreadable. */
  readonly status: MiAccountIndexStatus;
  /** Valid entries only; always empty for `missing` and `corrupt`. */
  readonly entries: readonly MiAccountIndexEntry[];
}

function parseAccountIndexEntries(parsed: readonly unknown[]): MiAccountIndexEntry[] { const out: MiAccountIndexEntry[] = [];
  const seen = new Set<string>();
  for (const item of parsed) { if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const rec = item as Record<string, unknown>;
    const id = typeof rec["id"] === "string" ? rec["id"].trim() : "";
    const rawSlot = typeof rec["slotId"] === "string" ? rec["slotId"].trim() : "";
    if (!id || seen.has(id)) continue;
    let slotId: string;
    try { slotId = normalizeMiCredentialSlotId(rawSlot || id);
    } catch { continue;
    }
    seen.add(id);
    const region = normalizeMiCloudRegion(rec["region"]);
    const maskedUserId = typeof rec["maskedUserId"] === "string" && rec["maskedUserId"].trim() !== ""
        ? rec["maskedUserId"].trim()
        : "****";
    out.push({ id, slotId, region, maskedUserId });
  }
  return out;
}

/**
 * Reads the persisted account index together with its storage state (#228).
 *
 * The old reader returned `[]` for both "no index yet" and "index exists but cannot be parsed",
 * which let `loadUnlocked` treat corruption as an empty account list: cached secondaries were
 * dropped and the corrupt value was overwritten with a primary-only index.
 */
export function readAccountIndexState(storage: Storage | null = defaultStorage()): MiAccountIndexSnapshot { if (!storage) return { status: "missing", entries: [] };
  let raw: string | null;
  try { raw = storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
  } catch {
    // Unreadable storage is not proof that no accounts exist; fail closed instead of clearing.
    return { status: "corrupt", entries: [] };
  }
  if (!raw) return { status: "missing", entries: [] };
  let parsed: unknown;
  try { parsed = JSON.parse(raw);
  } catch { return { status: "corrupt", entries: [] };
  }
  if (!Array.isArray(parsed)) return { status: "corrupt", entries: [] };
  const entries = parseAccountIndexEntries(parsed);
  // A non-empty array where no entry survives validation is corruption, not "no accounts":
  // `writeAccountIndex` never stores such a value, and treating it as empty drops every slot.
  if (parsed.length > 0 && entries.length === 0) return { status: "corrupt", entries: [] };
  return { status: "ok", entries };
}

export function readAccountIndex(storage: Storage | null = defaultStorage()): MiAccountIndexEntry[] {
  return [...readAccountIndexState(storage).entries];
}

export function hasSecondaryMiAccountsInIndex(storage: Storage | null = defaultStorage()): boolean { if (!storage) return false;
  try { const raw = storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
    if (!raw) return false;
    const parsed: unknown = JSON.parse(raw);
    // Raw length, not the validated entry count: a partially damaged index must still trigger
    // hydration so the surviving secondary entry is read and the index is repaired.
    return Array.isArray(parsed) && parsed.length > 1;
  } catch { return false;
  }
}

export function hasCorruptMiAccountIndex(storage: Storage | null = defaultStorage()): boolean {
  return readAccountIndexState(storage).status === "corrupt";
}

function writeAccountIndex(storage: Storage | null,
  accounts: readonly MiAccount[],
): boolean { if (!storage) return false;
  try { if (accounts.length === 0) { storage.removeItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
      return false;
    }
    const entries: MiAccountIndexEntry[] = accounts.map((acc) => ({
      id: acc.id,
      slotId: acc.slotId,
      region: acc.region,
      maskedUserId: acc.maskedUserId,
    }));
    storage.setItem(MI_ACCOUNTS_INDEX_STORAGE_KEY, JSON.stringify(entries));
    return true;
  } catch {
    return false;
  }
}

function accountIndexMatches(storage: Storage | null, accounts: readonly MiAccount[]): boolean {
  const state = readAccountIndexState(storage);
  if (state.status === "missing") return accounts.length === 0;
  if (state.status !== "ok" || state.entries.length !== accounts.length) return false;
  return accounts.every((account, index) => {
    const entry = state.entries[index]!;
    return entry.id === account.id
      && entry.slotId === account.slotId
      && entry.region === account.region
      && entry.maskedUserId === account.maskedUserId;
  });
}

export type MiAccountsReadState = "complete" | "partial";

export class MiAccountsStore { private cachedAccounts: MiAccount[] = [];
  private loaded = false;
  private lastWroteIndexToStorage = false;
  private firstLoadDone = false;
  private accountsReadState: MiAccountsReadState = "complete";
  private primaryConfirmed = false;
  /** The last load's `mi_session` read failed; a cached first account is not its owner. */
  private lastPrimaryReadFailed = false;
  /** Slot sessions from the last successful enumeration; used to clear leftovers on sign-out. */
  private enumeratedSessions: Readonly<Record<string, MiSession>> | null = null;
  private opQueue: Promise<unknown> = Promise.resolve();

  constructor(private readonly vault: CredentialVault = new CredentialVault(),
    private readonly storage: Storage | null = defaultStorage(),
  ) {}

  private enqueue<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.opQueue.then(fn, fn);
    this.opQueue = run.then(() => undefined, () => undefined);
    return run;
  }

  private syncExternalRevocation(): void {
    if (!this.lastWroteIndexToStorage || this.cachedAccounts.length === 0 || !this.storage) return;
    try {
      if (this.storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY) === null) {
        this.cachedAccounts = [];
        this.loaded = false;
        this.lastWroteIndexToStorage = false;
      }
    } catch {
    }
  }

  getAccounts(): readonly MiAccount[] { this.syncExternalRevocation();
    return this.cachedAccounts;
  }

  /**
   * Credential slots a sign-out or removal of `accountId` owns: its canonical slot plus any
   * enumerated alias that resolves to the same identity. Never includes another account (#228).
   */
  credentialSlotIdsForAccount(accountId: string): string[] { const account = this.getAccounts().find((item) => item.id === accountId);
    return account ? this.slotIdsForAccount(account) : [];
  }

  primarySession(): MiSession | null { this.syncExternalRevocation();
    return this.cachedAccounts[0]?.session ?? null;
  }

  /** `partial` drives a non-blocking notice: some credentials could not be read this load. */
  getAccountsReadState(): MiAccountsReadState { return this.accountsReadState;
  }

  /**
   * True only when this load read `mi_session` successfully or promoted a secondary into it. A
   * failed primary read can still yield a cached/secondary first account; settings must not adopt
   * that session as the primary.
   */
  hasConfirmedPrimarySession(): boolean { return this.primaryConfirmed;
  }

  /** Re-reads `mi_session` to prove a just-recovered primary is still the stored credential. */
  async checkPrimarySession(session: MiSession): Promise<"current" | "stale" | "unavailable"> {
    const current = await this.vault.loadPrimaryMiSession();
    if (this.vault.didLastPrimaryMiSessionReadFail()) return "unavailable";
    if (current === null) return "stale";
    return miSessionFingerprint(current) === miSessionFingerprint(session) ? "current" : "stale";
  }

  async load(): Promise<MiAccount[]> {
    return this.enqueue(() => this.loadUnlocked());
  }

  /**
   * Credentials are the source of truth for which accounts exist; the index only orders them and
   * supplies display metadata (#228). Enumeration is additive and runs on the first load of a
   * cold store (plus a corrupt/missing index with an empty cache), never on every poll.
   */
  private async loadUnlocked(): Promise<MiAccount[]> { this.syncExternalRevocation();
    const indexState = readAccountIndexState(this.storage);
    const index = indexState.entries;
    const indexUnreadable = indexState.status === "corrupt";
    let primaryReadFailed = false;
    let primarySession: MiSession | null = null;
    try {
      primarySession = await this.vault.loadPrimaryMiSession();
      if (this.vault.didLastPrimaryMiSessionReadFail?.() === true) primaryReadFailed = true;
    } catch {
      primaryReadFailed = true;
    }
    const primaryAccount = primarySession ? makeMiAccount(primarySession) : null;
    if (!primaryReadFailed && !indexUnreadable && this.storage !== null && index.length === 0 && this.cachedAccounts.length > 0) {
      this.cachedAccounts = [];
    }

    const shouldEnumerate = !this.firstLoadDone
      || ((indexState.status !== "ok") && this.cachedAccounts.length === 0);
    const scannedSlotIds = shouldEnumerate
      ? await this.vault.listMiAccountSlotIds().catch(() => null)
      : null;

    const slotIds: string[] = [];
    const pushSlot = (slotId: string): void => { if (!slotIds.includes(slotId)) slotIds.push(slotId);
    };
    for (const entry of index) pushSlot(entry.slotId);
    for (const cached of this.cachedAccounts) pushSlot(cached.slotId);
    for (const slotId of scannedSlotIds ?? []) pushSlot(slotId);

    let slotsReadFailed = false;
    let loadedSlots: Record<string, MiSession> = {};
    try {
      loadedSlots = await this.vault.loadMiAccountSlots(slotIds);
      if (this.vault.didLastMiAccountSlotsReadFail?.() === true) slotsReadFailed = true;
    } catch {
      slotsReadFailed = true;
    }

    const ordered: MiAccount[] = [];
    const seenIds = new Set<string>();
    const pushAccount = (account: MiAccount): void => { if (seenIds.has(account.id)) return;
      seenIds.add(account.id);
      ordered.push(account);
    };

    if (primaryAccount) pushAccount(primaryAccount);
    else if (primaryReadFailed && this.cachedAccounts.length > 0) pushAccount(this.cachedAccounts[0]!);

    // Index order first, then cached accounts that outlived the index, then newly discovered slots.
    for (const slotId of slotIds) { const session = loadedSlots[slotId];
      if (session) pushAccount(makeMiAccount(session));
    }

    // The vault cannot distinguish "missing" from "unreadable": a slot that is not in `loadedSlots`
    // may have thrown, returned null or held invalid content. Keep the in-memory account in every
    // such case, independent of whether this load enumerated (#228).
    for (const cached of this.cachedAccounts) { if (seenIds.has(cached.id)) continue;
      if (loadedSlots[cached.slotId] !== undefined) continue;
      pushAccount(cached);
    }

    const promoted = !primaryAccount && !primaryReadFailed && ordered.length > 0;
    if (promoted) { const first = ordered[0]!;
      await this.vault.savePrimaryMiSession(first.session);
      await this.vault.deleteMiAccountSlot(first.slotId).catch(() => {});
    }
    // A transient read failure must not revoke ownership already established for the retained
    // cached primary; otherwise removing it would skip clearing `mi_session`.
    const retainedCachedPrimary = !primaryAccount && primaryReadFailed && this.cachedAccounts.length > 0;
    this.primaryConfirmed = Boolean(primaryAccount)
      || promoted
      || (retainedCachedPrimary && this.primaryConfirmed);
    this.lastPrimaryReadFailed = primaryReadFailed && !promoted;

    if (scannedSlotIds !== null) this.enumeratedSessions = { ...loadedSlots };
    const unreadScannedSlots = scannedSlotIds !== null
      ? scannedSlotIds.filter((slotId) => loadedSlots[slotId] === undefined)
      : [];
    // Index/cache slots count too: the vault cannot distinguish missing from unreadable, so any
    // known slot without a parsed session keeps its cached account and marks the read partial.
    const primarySlotId = primaryAccount?.slotId
      ?? (primaryReadFailed && this.primaryConfirmed ? this.cachedAccounts[0]?.slotId : undefined);
    const unreadKnownSlots = slotIds.filter((slotId) =>
      slotId !== primarySlotId && loadedSlots[slotId] === undefined);
    this.accountsReadState = slotsReadFailed
      || unreadKnownSlots.length > 0
      || unreadScannedSlots.length > 0
      || (indexUnreadable && scannedSlotIds === null)
      ? "partial"
      : "complete";
    this.firstLoadDone = true;
    this.cachedAccounts = ordered;
    this.loaded = true;

    // A corrupt index is only replaced once enumeration proved the list is complete; otherwise the
    // damaged raw value and the in-memory accounts stay untouched.
    const indexWritable = !primaryReadFailed
      && !slotsReadFailed
      && (!indexUnreadable || (scannedSlotIds !== null && unreadScannedSlots.length === 0));
    if (indexWritable && !accountIndexMatches(this.storage, ordered)) {
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, ordered);
    }
    return [...ordered];
  }

    async upsertAccount(rawSession: MiSession): Promise<{ readonly accounts: MiAccount[];
    readonly account: MiAccount;
    readonly added: boolean;
    readonly primarySessionKnown: boolean;
  }> { const parsed = parseMiSession(rawSession);
    if (!parsed) { throw new Error("Invalid Xiaomi session");
    }
    const account = makeMiAccount(parsed);
    const serialized = serializeMiSession(account.session);
    if (serialized.length === 0) { throw new Error("Empty Xiaomi session");
    }
    assertCredentialBlobWithinLimit(serialized, `mi_session_${account.slotId}`);
    if (new TextEncoder().encode(serialized).byteLength > WIN32_CRED_MAX_BLOB_BYTES) {
      throw new Error("Xiaomi session exceeds Win32 credential blob limit");
    }

    return this.enqueue(async () => {
      if (!this.loaded) { await this.loadUnlocked();
      }

      const existingIdx = this.cachedAccounts.findIndex((item) => item.id === account.id);
      if (existingIdx === 0) { const previousSession = this.cachedAccounts[0]!.session;
        const prevFp = miSessionFingerprint(previousSession);
        const ownsPrimary = this.primaryConfirmed;
        if (ownsPrimary) {
          await this.vault.savePrimaryMiSession(account.session);
          this.primaryConfirmed = true;
          this.lastPrimaryReadFailed = false;
        } else {
          // The first cached account is a recovered secondary; never overwrite an unread primary.
          await this.vault.saveMiAccountSlot(account.slotId, account.session);
        }
        if (prevFp !== miSessionFingerprint(account.session)) { clearPersistedMiSessionExpiredFor(previousSession, this.storage);
          markAccountSessionRejected(account.session, false, {
            isPrimary: ownsPrimary,
            storage: this.storage,
          });
        }
        this.cachedAccounts = [account, ...this.cachedAccounts.slice(1)];
        this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
        return { accounts: [...this.cachedAccounts], account, added: false, primarySessionKnown: this.primaryConfirmed };
      }

      if (existingIdx > 0) { const previousSession = this.cachedAccounts[existingIdx]!.session;
        const prevFp = miSessionFingerprint(previousSession);
        await this.vault.saveMiAccountSlot(account.slotId, account.session);
        if (prevFp !== miSessionFingerprint(account.session)) { clearPersistedMiSessionExpiredFor(previousSession, this.storage);
          markAccountSessionRejected(account.session, false, {
            isPrimary: false,
            storage: this.storage,
          });
        }
        const next = [...this.cachedAccounts];
        next[existingIdx] = account;
        this.cachedAccounts = next;
        this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
        return { accounts: [...this.cachedAccounts], account, added: false, primarySessionKnown: this.primaryConfirmed };
      }

      if (this.cachedAccounts.length === 0) {
        // If `mi_session` could not be read, a new login must not overwrite it; write a slot and
        // leave the unread primary intact for a later load.
        const ownsPrimary = !this.lastPrimaryReadFailed;
        if (ownsPrimary) {
          await this.vault.savePrimaryMiSession(account.session);
          this.primaryConfirmed = true;
          this.lastPrimaryReadFailed = false;
        } else {
          await this.vault.saveMiAccountSlot(account.slotId, account.session);
        }
        markAccountSessionRejected(account.session, false, {
          isPrimary: ownsPrimary,
          storage: this.storage,
        });
        this.cachedAccounts = [account];
        this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
        return { accounts: [...this.cachedAccounts], account, added: true, primarySessionKnown: this.primaryConfirmed };
      }

      await this.vault.saveMiAccountSlot(account.slotId, account.session);
      markAccountSessionRejected(account.session, false, {
        isPrimary: false,
        storage: this.storage,
      });
      this.cachedAccounts = [...this.cachedAccounts, account];
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
      return { accounts: [...this.cachedAccounts], account, added: true, primarySessionKnown: this.primaryConfirmed };
    });
  }

  /**
   * Slot ids for `account`, including duplicates seen by the last enumeration. Never triggers a
   * new scan: a normal index removal stays independent from the rest of the credential store, and
   * an unknown leftover slot can surface on a later cold start for the user to remove again (#228).
   */
  private slotIdsForAccount(account: MiAccount): string[] {
    const slots = new Set<string>([account.slotId]);
    for (const [slotId, session] of Object.entries(this.enumeratedSessions ?? {})) {
      if (makeMiAccount(session).id === account.id) slots.add(slotId);
    }
    return [...slots];
  }

    async removeAccount(accountId: string,
    selectedHomeId?: string | null,
  ): Promise<{ readonly accounts: MiAccount[];
    readonly primarySession: MiSession | null;
    /** False when the first cached account is not a confirmed primary; callers must keep settings. */
    readonly primarySessionKnown: boolean;
    readonly resetSelectedHome: boolean;
  }> { return this.enqueue(async () => {
      if (!this.loaded) { await this.loadUnlocked();
      }
      const idx = this.cachedAccounts.findIndex((item) => item.id === accountId);
      if (idx < 0) { return {
          accounts: [...this.cachedAccounts],
          primarySession: this.primarySession(),
          primarySessionKnown: this.primaryConfirmed,
          resetSelectedHome: false,
        };
      }

      const removed = this.cachedAccounts[idx]!;
      const ownsPrimary = this.primaryConfirmed;
      const resetSelectedHome = Boolean(selectedHomeId &&
          (MiAccountScope.isOwned(selectedHomeId, accountId) ||
            (MiAccountScope.owner(selectedHomeId) === null && idx === 0)),
      );

      const slotsForRemoval = this.slotIdsForAccount(removed);
      const remaining = this.cachedAccounts.filter((item) => item.id !== accountId);
      if (idx === 0 && ownsPrimary) { if (remaining.length === 0) {
          // Remove only the selected account. `deleteMiSession()` would also wipe unrelated slots
          // that a failed read left in the vault's `known` map; those credentials are real and must
          // surface on a later load instead (#228).
          await this.vault.savePrimaryMiSession(null);
          for (const slotId of slotsForRemoval) await this.vault.deleteMiAccountSlot(slotId);
          // Only after every deletion: a failed retry must still know this account owned the primary.
          this.primaryConfirmed = false;
          this.lastPrimaryReadFailed = false;
        } else { const promoted = remaining[0]!;
          await this.vault.savePrimaryMiSession(promoted.session);
          for (const slotId of slotsForRemoval) await this.vault.deleteMiAccountSlot(slotId);
          await this.vault.deleteMiAccountSlot(promoted.slotId);
          this.primaryConfirmed = true;
          this.lastPrimaryReadFailed = false;
        }
      } else {
        // The first cached account is a recovered secondary, not the primary: never overwrite the
        // unread `mi_session` credential just because it sits at index zero (#228).
        for (const slotId of slotsForRemoval) await this.vault.deleteMiAccountSlot(slotId);
      }

      markAccountSessionRejected(removed.session, false, {
        isPrimary: ownsPrimary && idx === 0 && remaining.length === 0,
        storage: this.storage,
      });
      this.cachedAccounts = remaining;
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, remaining);
      return {
        accounts: [...remaining],
        primarySession: remaining[0]?.session ?? null,
        primarySessionKnown: ownsPrimary,
        resetSelectedHome,
      };
    });
  }

    async clearAll(): Promise<void> { return this.enqueue(async () => {
      if (!this.loaded) { await this.loadUnlocked();
      }
      const index = readAccountIndex(this.storage);
      const slotIds = new Set<string>([
        ...this.cachedAccounts.map((acc) => acc.slotId),
        ...index.map((entry) => entry.slotId),
      ]);
      // Any deletion failure propagates: the UI reports an incomplete sign-out and the user can
      // retry. Credentials that survive are real and may show up on the next cold start.
      await this.vault.deleteMiSession([...slotIds]);
      this.cachedAccounts = [];
      this.loaded = true;
      this.accountsReadState = "complete";
      this.primaryConfirmed = false;
      this.lastPrimaryReadFailed = false;
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, []);
      clearPersistedMiSessionExpired(this.storage);
    });
  }

  tokenStatuses(nowMs = Date.now()): Record<string, MiAccountTokenStatus> {
    const out: Record<string, MiAccountTokenStatus> = {};
    for (const acc of this.cachedAccounts) { out[acc.id] = getAccountTokenStatus(acc, nowMs, this.storage);
    }
    return out;
  }
}

export type AccountScopedSmartDevice = SmartDevice;

export interface AccountScopedHomeOption { readonly id: string;
  readonly name: string;
  readonly deviceCount: number;
  readonly isSharedHome?: boolean;
  readonly accountId?: string;
  readonly accountLabel?: string;
}

export interface AccountChildSnapshot { readonly account: MiAccount;
  readonly home: Omit<SynthesizedHome, "devices"> & { readonly devices: AccountScopedSmartDevice[] };
  readonly homes: readonly AccountScopedHomeOption[];
  readonly rawDevices: readonly MiDeviceRecord[];
  readonly allDevices: readonly MiDeviceRecord[];
  readonly allRooms: readonly MiRoom[];
  readonly specs: Readonly<Record<string, MiotDeviceSpec>>;
  readonly lightGroupOwners: ReadonlyMap<string, string>;
  /** Devices of a turned-off category whose enabled alerts still need their signal (P3a-W). */
  readonly safetyDevices?: readonly AccountScopedSmartDevice[];
  readonly safetyDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  /** Index entries of the cards the type selection withholds, for the host write gate. */
  readonly hiddenDevices?: readonly CapabilityIndexedDevice[];
  /** The prune plan's per-card signals, drawn or not, for the device-type preview. */
  readonly safetySignalsByDeviceId?: Readonly<Record<string, readonly SafetySignalKind[]>>;
  readonly status: ConnectionStatus;
  readonly tokenStatus: MiAccountTokenStatus;
  readonly error?: unknown;
}

export interface MergedMiAccountsSnapshot {
  readonly home: Omit<SynthesizedHome, "devices"> & { readonly devices: AccountScopedSmartDevice[] };
  readonly homes: AccountScopedHomeOption[];
  readonly accountStatuses: Readonly<Record<string, ConnectionStatus>>;
  readonly accountTokenStatuses: Readonly<Record<string, MiAccountTokenStatus>>;
  readonly deviceOwners: Readonly<Record<string, readonly string[]>>;
  readonly aggregateStatus: ConnectionStatus;
  readonly rawDevicesByAccount: Readonly<Record<string, readonly MiDeviceRecord[]>>;
  readonly allDevicesByAccount: Readonly<Record<string, readonly MiDeviceRecord[]>>;
  readonly allRoomsByAccount: Readonly<Record<string, readonly MiRoom[]>>;
  readonly specsByModel: Readonly<Record<string, MiotDeviceSpec>>;
  readonly lightGroupOwners: Map<string, string>;
  readonly resetSelectedHome: boolean;
  readonly staleDeviceIds: ReadonlySet<string>;
  /** Union of the children's alert-only devices and their facets; never shown as cards. */
  readonly safetyDevices?: readonly AccountScopedSmartDevice[];
  readonly safetyDeviceFacets?: Readonly<Record<string, readonly FacetControl[]>>;
  /** Union of the children's withheld index entries, for the host write gate. */
  readonly hiddenDevices?: readonly CapabilityIndexedDevice[];
  /** First-seen union of the connected children's per-card signals. */
  readonly safetySignalsByDeviceId?: Readonly<Record<string, readonly SafetySignalKind[]>>;
}

export function buildHomeOptionsFromMiRooms(rooms: readonly MiRoom[],
): AccountScopedHomeOption[] { const order: string[] = [];
  const names = new Map<string, string>();
  const shared = new Map<string, boolean>();
  const dids = new Map<string, Set<string>>();
  for (const room of rooms) { const hid = room.homeId ?? "";
    if (!hid) continue;
    if (!names.has(hid)) { order.push(hid);
      names.set(hid, room.homeName ?? "");
      shared.set(hid, room.isSharedHome === true);
      dids.set(hid, new Set());
    } else if (room.isSharedHome === true) { shared.set(hid, true);
    }
    const set = dids.get(hid)!;
    for (const did of room.dids) set.add(did);
  }
  return order.map((id) => ({
    id,
    name: names.get(id) ?? "",
    deviceCount: dids.get(id)?.size ?? 0,
    ...(shared.get(id) ? { isSharedHome: true as const } : {}),
  }));
}

function stampAccountSnapshot(home: SynthesizedHome,
  homes: readonly AccountScopedHomeOption[],
  account: MiAccount,
  namespaceIds = true,
): { readonly home: Omit<SynthesizedHome, "devices"> & { readonly devices: AccountScopedSmartDevice[] };
  readonly homes: AccountScopedHomeOption[];
} { const prefix = namespaceIds ? `${account.id}/` : "";
  const rooms: RoomCategory[] = home.rooms.map((room) => ({
    ...room,
    id: `${prefix}${room.id}`,
  }));
  const devices: AccountScopedSmartDevice[] = home.devices.map((device) => ({
    ...device,
    roomId: `${prefix}${device.roomId}`,
    accountId: account.id,
    accountLabel: account.maskedUserId,
  }));
  const stampedHomes: AccountScopedHomeOption[] = homes.map((option) => ({
    ...option,
    id: `${prefix}${option.id}`,
    accountId: account.id,
    accountLabel: account.maskedUserId,
  }));
  return {
    home: {
      ...home,
      rooms,
      devices,
    },
    homes: stampedHomes,
  };
}

function extractDeviceMiotCommandDids(device: SmartDevice,
  facets: readonly FacetControl[] = [],
): string[] { const dids = new Set<string>();
  const addAddress = (entityId: string | null | undefined): void => { if (!entityId) return;
    const action = parseMiotActionAddress(entityId);
    if (action) { dids.add(action.did);
      return;
    }
    const prop = parseMiotAddress(entityId);
    if (prop) { dids.add(prop.did);
    }
  };

  const k = device.kind;
  switch (k.kind) { case "light": case "climate": case "fan": addAddress(k.entityId);
      break;
    case "plug": addAddress(k.switchEntityId);
      addAddress(k.childLockEntityId);
      break;
    case "fridge": addAddress(k.modeEntityId);
      addAddress(k.fridgeTargetEntityId);
      addAddress(k.freezerTargetEntityId);
      break;
    case "vacuum": addAddress(k.entityId);
      addAddress(k.modeEntityId);
      break;
    case "camera": addAddress(k.entityId);
      addAddress(k.motionDetectionEntityId);
      if (k.gatewayDid) dids.add(k.gatewayDid);
      break;
    case "cover": addAddress(k.entityId);
      break;
    case "speaker": addAddress(k.mediaEntityId);
      addAddress(k.muteSwitchEntityId);
      addAddress(k.sleepModeEntityId);
      addAddress(k.ttsActionId);
      addAddress(k.directiveActionId);
      break;
    case "tv": addAddress(k.mediaEntityId);
      addAddress(k.muteSwitchEntityId);
      addAddress(k.powerOnActionId);
      addAddress(k.powerOffActionId);
      break;
    case "humidifier": addAddress(k.entityId);
      break;
    case "appliance": addAddress(k.entityId);
      addAddress(k.powerEntityId);
      addAddress(k.modeEntityId);
      addAddress(k.temperatureEntityId);
      addAddress(k.light?.entityId);
      addAddress(k.fanLevel?.entityId);
      addAddress(k.startAction?.entityId);
      addAddress(k.pauseAction?.entityId);
      addAddress(k.stopAction?.entityId);
      break;
    case "generic": addAddress(k.powerControl?.target?.entityId);
      break;
    case "sensor":
      break;
  }
  for (const facet of facets) { addAddress(facet.target?.entityId);
  }
  return [...dids];
}

function aggregateAccountConnectionStatus(accounts: readonly MiAccount[],
  statuses: Readonly<Record<string, ConnectionStatus>>,
): ConnectionStatus { if (accounts.length === 0) { return {
      kind: "disconnected",
      reason: tr3("尚未登录小米账号", "尚未登入小米帳號", "Not signed in to Xiaomi account"),
    };
  }
  let connected = false;
  let seenConnecting = false;
  let firstDisconnected: ConnectionStatus | null = null;
  for (const account of accounts) { const status = statuses[account.id];
    if (!status) continue;
    if (status.kind === "connected") { connected = true;
    } else if (status.kind === "connecting") { seenConnecting = true;
    } else if (firstDisconnected === null) { firstDisconnected = status;
    }
  }
  if (connected) return { kind: "connected" };
  if (seenConnecting) return { kind: "connecting" };
  return firstDisconnected ?? { kind: "connecting" };
}

export function mergeMiAccountSnapshots(accounts: readonly MiAccount[],
  children: Readonly<Record<string, AccountChildSnapshot>>,
  resetSelectedHome = false,
): MergedMiAccountsSnapshot { const rooms: RoomCategory[] = [];
  const devices: AccountScopedSmartDevice[] = [];
  const readings: EnvironmentReading[] = [];
  const scenes: HomeScene[] = [];
  const homes: AccountScopedHomeOption[] = [];
  const roomIds = new Set<string>();
  const deviceIds = new Set<string>();
  const staleDeviceIds = new Set<string>();
  const seenPhysicalDids = new Set<string>();
  const deviceIndexById = new Map<string, number>();
  const deviceConnectedById = new Map<string, boolean>();
  const readingIds = new Set<string>();
  const readingConnectedById = new Map<string, boolean>();
  const sceneIds = new Set<string>();
  const homeIds = new Set<string>();
  const facetsByDevice: Record<string, readonly FacetControl[]> = {};
  const lightGroupOwners = new Map<string, string>();
  const lightGroupConnected = new Map<string, boolean>();
  const ownersMutable: Record<string, string[]> = {};
  const accountStatuses: Record<string, ConnectionStatus> = {};
  const accountTokenStatuses: Record<string, MiAccountTokenStatus> = {};
  const rawDevicesByAccount: Record<string, readonly MiDeviceRecord[]> = {};
  const allDevicesByAccount: Record<string, readonly MiDeviceRecord[]> = {};
  const allRoomsByAccount: Record<string, readonly MiRoom[]> = {};
  const specsByModel: Record<string, MiotDeviceSpec> = {};
  const safetyDevices: AccountScopedSmartDevice[] = [];
  const safetyDeviceFacets: Record<string, readonly FacetControl[]> = {};
  const safetyDeviceIds = new Set<string>();
  const hiddenDevices: CapabilityIndexedDevice[] = [];
  const hiddenDeviceIds = new Set<string>();
  const safetySignalsByDeviceId: Record<string, readonly SafetySignalKind[]> = Object.create(null);

  for (const account of accounts) { const child = children[account.id];
    if (!child) continue;
    const isConnected = child.status.kind === "connected";
    accountStatuses[account.id] = child.status;
    accountTokenStatuses[account.id] = child.tokenStatus;
    rawDevicesByAccount[account.id] = child.rawDevices;
    allDevicesByAccount[account.id] = child.allDevices;
    allRoomsByAccount[account.id] = child.allRooms;
    for (const [model, spec] of Object.entries(child.specs)) { if (!specsByModel[model]) specsByModel[model] = spec;
    }

    // Alert-only devices stay off the panel but still feed evaluation, so a connected account's
    // retained sensors merge first-seen like cards do. Two accounts can hold the same raw did, and
    // their index entries are only the same device when the source scope matches too.
    if (isConnected) { for (const device of child.safetyDevices ?? []) { if (safetyDeviceIds.has(device.id)) continue;
        safetyDeviceIds.add(device.id);
        safetyDevices.push(device);
        const facets = child.safetyDeviceFacets?.[device.id];
        if (facets && facets.length > 0) safetyDeviceFacets[device.id] = facets;
      }
      for (const [id, signals] of Object.entries(child.safetySignalsByDeviceId ?? {})) {
        if (!(id in safetySignalsByDeviceId)) safetySignalsByDeviceId[id] = signals;
      }
    }
    // The identity index is not an alert: a round that failed keeps drawing the account's last
    // cards, so it must keep naming their closed types too. Availability drops instead, so a stale
    // entry can never authorize a write while the account is not answering.
    for (const hidden of child.hiddenDevices ?? []) { const key = `${hidden.sourceScope}|${hidden.id}`;
      if (hiddenDeviceIds.has(key)) continue;
      hiddenDeviceIds.add(key);
      hiddenDevices.push(isConnected ? hidden : { ...hidden, isSourceAvailable: false });
    }

    const childFacets = child.home.deviceFacets ?? {};
    for (const device of child.home.devices) {
      const cmdDids = extractDeviceMiotCommandDids(device, childFacets[device.id] ?? []);
      for (const key of [device.id, ...cmdDids]) { const list = (ownersMutable[key] ??= []);
        if (list.includes(account.id)) continue;
        if (isConnected) {
          const firstNonConnectedIdx = list.findIndex((id) => children[id]?.status.kind !== "connected");
          if (firstNonConnectedIdx >= 0) { list.splice(firstNonConnectedIdx, 0, account.id);
          } else { list.push(account.id); }
        } else { list.push(account.id); }
      }
    }

    for (const room of child.home.rooms) { if (!roomIds.has(room.id)) { roomIds.add(room.id);
        rooms.push(room);
      }
    }

    for (const device of child.home.devices) { const baseDid = device.id;
      const nextDevice: AccountScopedSmartDevice = isConnected
        ? (device.telemetryStale ? { ...device, telemetryStale: false } : device)
        : { ...device, telemetryStale: true };
      const existingIdx = deviceIndexById.get(device.id);
      if (existingIdx !== undefined || seenPhysicalDids.has(baseDid)) {
        if (existingIdx !== undefined && isConnected && !deviceConnectedById.get(device.id)) {
          devices[existingIdx] = nextDevice;
          deviceConnectedById.set(device.id, true);
          staleDeviceIds.delete(device.id);
          const facets = childFacets[device.id];
          if (facets && facets.length > 0) { facetsByDevice[device.id] = facets;
          } else { delete facetsByDevice[device.id]; }
          if (readingIds.has(device.id) && !readingConnectedById.get(device.id)) {
            readingIds.delete(device.id);
            readingConnectedById.delete(device.id);
            const rIdx = readings.findIndex((r) => r.id === device.id);
            if (rIdx >= 0) readings.splice(rIdx, 1);
          }
        }
        continue;
      }
      deviceIds.add(device.id);
      seenPhysicalDids.add(baseDid);
      deviceIndexById.set(device.id, devices.length);
      deviceConnectedById.set(device.id, isConnected);
      if (!isConnected) staleDeviceIds.add(device.id);
      devices.push(nextDevice);
      const facets = childFacets[device.id];
      if (facets && facets.length > 0) { facetsByDevice[device.id] = facets;
      }
    }

    for (const [memberDid, groupDid] of child.lightGroupOwners) {
      if (!lightGroupOwners.has(memberDid) || (isConnected && !lightGroupConnected.get(memberDid))) {
        lightGroupOwners.set(memberDid, groupDid);
        lightGroupConnected.set(memberDid, isConnected);
      }
    }

    for (const reading of child.home.environmentReadings) {
      if (!deviceIds.has(reading.id)) continue;
      if (readingIds.has(reading.id)) {
        if (isConnected && !readingConnectedById.get(reading.id)) {
          const rIdx = readings.findIndex((r) => r.id === reading.id);
          if (rIdx >= 0) readings[rIdx] = reading;
          readingConnectedById.set(reading.id, true);
        }
        continue;
      }
      readingIds.add(reading.id);
      readingConnectedById.set(reading.id, isConnected);
      readings.push(reading);
    }

    for (const scene of child.home.scenes) {
      if (!sceneIds.has(scene.id)) {
        sceneIds.add(scene.id);
        scenes.push({
          ...scene,
          accountId: scene.accountId ?? account.id,
          sourceBackend: scene.sourceBackend ?? "xiaomiCloud",
        });
      }
    }

    for (const option of child.homes) { if (!homeIds.has(option.id)) { homeIds.add(option.id);
        homes.push(option);
      }
    }
  }

  const filteredGroupOwners = new Map<string, string>();
  for (const [memberDid, groupDid] of lightGroupOwners) { if (deviceIds.has(memberDid) && deviceIds.has(groupDid)) {
      filteredGroupOwners.set(memberDid, groupDid);
    }
  }

  const priorityById = new Map(devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
  );
  readings.sort((a, b) => (priorityById.get(a.id) ?? 3) - (priorityById.get(b.id) ?? 3));

  return {
    home: {
      rooms,
      devices,
      environmentReadings: readings,
      scenes,
      ...(Object.keys(facetsByDevice).length > 0 ? { deviceFacets: facetsByDevice } : {}),
    },
    homes,
    accountStatuses,
    accountTokenStatuses,
    deviceOwners: ownersMutable,
    aggregateStatus: aggregateAccountConnectionStatus(accounts, accountStatuses),
    rawDevicesByAccount,
    allDevicesByAccount,
    allRoomsByAccount,
    specsByModel,
    lightGroupOwners: filteredGroupOwners,
    resetSelectedHome,
    staleDeviceIds,
    safetyDevices,
    safetyDeviceFacets,
    hiddenDevices,
    safetySignalsByDeviceId,
  };
}

function collectAccountMiotPropKeys(
  rawDevices: readonly MiDeviceRecord[],
  specs: Readonly<Record<string, MiotDeviceSpec>>,
): MiotPropKey[] {
  const propKeys: MiotPropKey[] = [];
  const seen = new Set<string>();
  const addKeys = (keys: readonly MiotPropKey[]) => {
    for (const key of keys) {
      const id = `${key.did}.${key.siid}.${key.piid}`;
      if (seen.has(id)) continue;
      seen.add(id);
      propKeys.push(key);
    }
  };
  for (const dev of rawDevices) {
    const spec = specs[dev.model];
    if (spec) {
      addKeys(MiotSynthesizer.requiredProps(dev, spec));
      addKeys(MiotSynthesizer.facetProps(dev, spec));
    }
  }
  return propKeys;
}

function filterDevicesByRawHomeSelection(
  devices: readonly MiDeviceRecord[],
  rooms: readonly MiRoom[],
  rawSelectedHomeId: string | null,
): { devices: MiDeviceRecord[]; rooms: MiRoom[] } {
  if (!rawSelectedHomeId) {
    return { devices: [...devices], rooms: [...rooms] };
  }
  if (rawSelectedHomeId === MiAccountScope.OTHER_ACCOUNT_HOME_SENTINEL) {
    return { devices: [], rooms: [] };
  }
  const hasHome = rooms.some((room) => room.homeId === rawSelectedHomeId);
  if (!hasHome) {
    return { devices: [...devices], rooms: [...rooms] };
  }
  const homeRooms = rooms.filter((room) => room.homeId === rawSelectedHomeId);
  const dids = new Set(homeRooms.flatMap((room) => room.dids));
  const kept = devices.filter(
    (d) => dids.has(d.did) || (d.splitParentDid ? dids.has(d.splitParentDid) : false),
  );
  const keptSet = new Set(kept);
  const parents = new Set(
    kept.map((d) => d.splitParentDid).filter((x): x is string => Boolean(x)),
  );
  const withParents = devices.filter((d) => keptSet.has(d) || parents.has(d.did));
  return { devices: withParents, rooms: homeRooms };
}

function buildMemberGroupOwners(
  membersByGroup: ReadonlyMap<string, readonly string[]>,
): Map<string, string> {
  const owners = new Map<string, string>();
  for (const [groupDid, memberDids] of membersByGroup) {
    for (const memberDid of memberDids) {
      if (!owners.has(memberDid)) {
        owners.set(memberDid, groupDid);
      }
    }
  }
  return owners;
}

interface AccountBackoffEntry {
  fingerprint: string;
  consecutiveHits: number;
  backoffUntilMs: number;
}

const perAccountBackoffMap = new Map<string, AccountBackoffEntry>();

function getAccountRateLimitBackoffUntilMs(
  account: MiAccount,
  nowMs = Date.now(),
): number | null {
  const entry = perAccountBackoffMap.get(account.id);
  if (!entry) return null;
  if (entry.fingerprint !== miSessionFingerprint(account.session)) {
    perAccountBackoffMap.delete(account.id);
    return null;
  }
  return entry.backoffUntilMs > nowMs ? entry.backoffUntilMs : null;
}

export function clearAccountRateLimitBackoff(accountId?: string): void {
  if (accountId === undefined) {
    perAccountBackoffMap.clear();
  } else {
    perAccountBackoffMap.delete(accountId);
  }
}

interface RefreshMiAccountsOptions {
  readonly accounts: readonly MiAccount[];
  readonly transport: HttpTransport;
  readonly specResolver: MiotSpecResolver;
  readonly selectedHomeId?: string | null;
  readonly silent?: boolean;
  readonly nowMs?: number;
  readonly storage?: Storage | null;
  readonly namespaceSingleAccount?: boolean;
  readonly previousSnapshots?: Readonly<Record<string, AccountChildSnapshot>>;
  readonly clientFactory?: (session: MiSession, transport: HttpTransport) => MiCloudClient;
  /** Device-type pruning inputs; absent means every card is synthesized and read as before. */
  readonly prune?: MiotAccountPruneOptions;
}

export interface MiotAccountPruneOptions {
  readonly selection: CapabilitySelection;
  readonly safetySignals: readonly SafetySignalKind[];
  /** Pinned cards, whose offline alert keeps only their topology record (P3a-W). */
  readonly starredDeviceIds?: readonly string[];
}

/** Connection scope of a Mi account, in the vocabulary the host selection stores. */
const miAccountScopeOf = (accountId: string): string => (accountId.startsWith("mi:") ? accountId : `mi:${accountId}`);

export async function discoverMiAccountDevicesAndRooms(
  client: MiCloudClient,
): Promise<{ devices: MiDeviceRecord[]; rooms: MiRoom[] }> {
  const discovered = await discoverMiHome(client, {
    unresolvedDids: new Set(),
    retryUnresolved: true,
    cachedRooms: () => null,
    onRoomsRead: () => {},
  });
  return { devices: discovered.devices, rooms: discovered.rooms };
}

export async function refreshMiAccountsConcurrently(options: RefreshMiAccountsOptions,
): Promise<{ readonly merged: MergedMiAccountsSnapshot;
  readonly children: Record<string, AccountChildSnapshot>;
}> { const { accounts,
    transport,
    specResolver,
    silent = false,
    nowMs = Date.now(),
    storage = defaultStorage(),
    previousSnapshots = {},
    clientFactory = (session, tp) => new MiCloudClient(session, tp),
  } = options;
  const namespaceIds = options.namespaceSingleAccount === true || accounts.length > 1;
  const allAccountIds = accounts.map((acc) => acc.id);
  let effectiveSelectedHomeId = options.selectedHomeId ?? null;
  let resetSelectedHome = false;

  for (let i = 0; i < accounts.length; i += 1) { const acc = accounts[i]!;
    const preStatus = getAccountTokenStatus(acc, nowMs, storage);
    if (preStatus.kind === "expired" &&
      effectiveSelectedHomeId &&
      (MiAccountScope.isOwned(effectiveSelectedHomeId, acc.id) ||
        (MiAccountScope.owner(effectiveSelectedHomeId) === null && i === 0))
    ) { effectiveSelectedHomeId = null;
      resetSelectedHome = true;
    }
  }

  const refreshOne = async (account: MiAccount,
    index: number,
  ): Promise<AccountChildSnapshot> => { const isPrimary = index === 0;
    const preTokenStatus = getAccountTokenStatus(account, nowMs, storage);
    if (preTokenStatus.kind === "expired" && (silent || preTokenStatus.source === "cookie")) { return {
        account,
        home: { rooms: [], devices: [], environmentReadings: [], scenes: [] },
        homes: [],
        rawDevices: [],
        allDevices: [],
        allRooms: [],
        specs: {},
        lightGroupOwners: new Map(),
        status: {
          kind: "disconnected",
          reason: formatAccountTokenNotice(account, preTokenStatus) ??
            tr3("登录已失效", "登入已失效", "Sign-in expired"),
        },
        tokenStatus: preTokenStatus,
      };
    }

    const backoffUntil = silent ? getAccountRateLimitBackoffUntilMs(account, nowMs) : null;
    if (backoffUntil !== null) { const previous = previousSnapshots[account.id];
      if (previous) return previous;
      return {
        account,
        home: { rooms: [], devices: [], environmentReadings: [], scenes: [] },
        homes: [],
        rawDevices: [],
        allDevices: [],
        allRooms: [],
        specs: {},
        lightGroupOwners: new Map(),
        status: {
          kind: "disconnected",
          reason: tr3("请求过于频繁，稍后自动重试", "請求過於頻繁，稍後自動重試", "Rate limited, retrying shortly"),
        },
        tokenStatus: preTokenStatus,
      };
    }

    try { const client = clientFactory(account.session, transport);
      const discovered = await discoverMiAccountDevicesAndRooms(client);
      const rawSelection = MiAccountScope.scopedSelectionForAccount(effectiveSelectedHomeId,
        account.id,
        allAccountIds,
      );
      const filtered = filterDevicesByRawHomeSelection(discovered.devices,
        discovered.rooms,
        rawSelection,
      );

      const groupDids = filtered.devices
        .map((d) => d.did)
        .filter((did) => did.startsWith("group."));
      // No group card is drawn while `light` is off, so the per-group membership read is waste (P2-10).
      const skipLightGroupMembers =
        options.prune !== undefined &&
        miotRoundClosesCategory(options.prune.selection, miAccountScopeOf(account.id), "light");
      const [specs, membersByGroup] = await Promise.all([
        specResolver.resolveForDevices(filtered.devices),
        groupDids.length > 0 && !skipLightGroupMembers
          ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
          : Promise.resolve(new Map<string, string[]>()),
      ]);

      const prune = options.prune
        ? buildMiotTypePrunePlan({
            rawDevices: filtered.devices,
            specs,
            selection: options.prune.selection,
            connectionScope: miAccountScopeOf(account.id),
            safetySignals: options.prune.safetySignals,
            ...(options.prune.starredDeviceIds ? { starredDeviceIds: options.prune.starredDeviceIds } : {}),
          })
        : null;
      // One plan per round: the same keys feed LAN/cloud batching, single source, dual source and
      // every account, and a closed category's alert-only devices keep just the reads they need.
      const propKeys = prune ? [...prune.readKeys] : collectAccountMiotPropKeys(filtered.devices, specs);
      const values = propKeys.length > 0
          ? await client.getProps(propKeys)
          : new Map<string, unknown>();

      const rawHome = MiotSynthesizer.synthesize(prune ? prune.visibleRecords : filtered.devices,
        filtered.rooms,
        specs,
        values,
      );
      const safetyHome = prune && prune.safetyRecords.length > 0
        ? MiotSynthesizer.synthesize(prune.safetyRecords, filtered.rooms, specs, values)
        : null;
      const rawHomes = buildHomeOptionsFromMiRooms(discovered.rooms);
      const stamped = stampAccountSnapshot(rawHome, rawHomes, account, namespaceIds);
      const stampedSafety = safetyHome ? stampAccountSnapshot(safetyHome, [], account, namespaceIds) : null;

      clearAccountRateLimitBackoff(account.id);
      markAccountSessionRejected(account.session, false, {
        isPrimary,
        storage,
        nowMs,
      });
      const freshTokenStatus = getAccountTokenStatus(account, nowMs, storage);
      return {
        account,
        home: stamped.home,
        homes: stamped.homes,
        rawDevices: filtered.devices,
        allDevices: discovered.devices,
        allRooms: discovered.rooms,
        specs,
        lightGroupOwners: buildMemberGroupOwners(membersByGroup),
        ...(stampedSafety
          ? { safetyDevices: stampedSafety.home.devices, safetyDeviceFacets: stampedSafety.home.deviceFacets ?? {} }
          : {}),
        ...(prune && prune.hiddenIndexedDevices.length > 0 ? { hiddenDevices: prune.hiddenIndexedDevices } : {}),
        ...(prune ? { safetySignalsByDeviceId: prune.safetySignalsByDeviceId } : {}),
        status: { kind: "connected" },
        tokenStatus: freshTokenStatus,
      };
    } catch (error) { if (error instanceof MiCloudError && error.kind === "sessionExpired") {
        markAccountSessionRejected(account.session, true, {
          isPrimary,
          storage,
          nowMs,
        });
        if (effectiveSelectedHomeId &&
          (MiAccountScope.isOwned(effectiveSelectedHomeId, account.id) ||
            (MiAccountScope.owner(effectiveSelectedHomeId) === null && isPrimary))
        ) { resetSelectedHome = true;
        }
        const expiredTokenStatus = getAccountTokenStatus(account, nowMs, storage);
        return {
          account,
          home: { rooms: [], devices: [], environmentReadings: [], scenes: [] },
          homes: [],
          rawDevices: [],
          allDevices: [],
          allRooms: [],
          specs: {},
          lightGroupOwners: new Map(),
          status: {
            kind: "disconnected",
            reason: error.message ||
              tr3("米家登录已失效", "米家登入已失效", "Xiaomi sign-in expired"),
          },
          tokenStatus: expiredTokenStatus,
          error,
        };
      }

      if (isXiaomiRateLimitError(error)) { const fp = miSessionFingerprint(account.session);
        const prev = perAccountBackoffMap.get(account.id);
        const hits = prev && prev.fingerprint === fp ? prev.consecutiveHits + 1 : 1;
        perAccountBackoffMap.set(account.id, {
          fingerprint: fp,
          consecutiveHits: hits,
          backoffUntilMs: nowMs + PollingPolicy.rateLimitBackoffMs(hits),
        });
      }

      const previous = previousSnapshots[account.id];
      const reason = error instanceof Error ? error.message : String(error);
      return {
        account,
        home: previous?.home ?? {
          rooms: [],
          devices: [],
          environmentReadings: [],
          scenes: [],
        },
        homes: previous?.homes ?? [],
        rawDevices: previous?.rawDevices ?? [],
        allDevices: previous?.allDevices ?? [],
        allRooms: previous?.allRooms ?? [],
        specs: previous?.specs ?? {},
        lightGroupOwners: previous?.lightGroupOwners ?? new Map(),
        // The panel keeps drawing this account's last snapshot, so it must keep answering
        // "该设备类型已关闭" for the same closed-type devices instead of "设备不存在" until the
        // account answers again (Nit-12).
        ...(previous?.hiddenDevices && previous.hiddenDevices.length > 0
          ? { hiddenDevices: previous.hiddenDevices }
          : {}),
        status: { kind: "disconnected", reason },
        tokenStatus: getAccountTokenStatus(account, nowMs, storage),
        error,
      };
    }
  };

  const settled = await Promise.all(accounts.map((account, index) => refreshOne(account, index)),
  );

  const children: Record<string, AccountChildSnapshot> = {};
  for (const child of settled) { children[child.account.id] = child;
  }

  if (resetSelectedHome && effectiveSelectedHomeId !== null) { effectiveSelectedHomeId = null;
    const retried = await Promise.all(accounts.map((account, index) => { const current = children[account.id];
        if (current && current.tokenStatus.kind === "expired") return Promise.resolve(current);
        return refreshOne(account, index);
      }),
    );
    for (const child of retried) { children[child.account.id] = child;
    }
  }

  const merged = mergeMiAccountSnapshots(accounts, children, resetSelectedHome);
  return { merged, children };
}

export async function executeMultiAccountMiotCommand(command: DeviceCommand,
  options: { readonly accounts: readonly MiAccount[];
    readonly deviceOwners: Readonly<Record<string, readonly string[]>>;
    readonly specsByModel: Readonly<Record<string, MiotDeviceSpec>>;
    readonly devices: readonly SmartDevice[];
    readonly transport: HttpTransport;
    readonly storage?: Storage | null;
    readonly beforeSend?: () => void;
    readonly clientFactory?: (session: MiSession, transport: HttpTransport) => MiCloudClient;
  },
): Promise<{ readonly executedByAccountId: string }> { const parsed =
    parseMiotActionAddress(command.entityId) ?? parseMiotAddress(command.entityId);
  if (!parsed) { throw new Error(`Invalid MIoT entity address: ${command.entityId}`);
  }
  const owners = options.deviceOwners[parsed.did] ?? [];
  if (owners.length === 0) { throw new Error(`No signed-in Xiaomi account owns device ${parsed.did}`);
  }
  const device = options.devices.find((item) =>
      item.id === parsed.did ||
      extractDeviceMiotCommandDids(item).includes(parsed.did),
  );
  const spec = device ? options.specsByModel[device.model] : undefined;
  if (!spec) { throw new Error(`Missing MIoT spec for device ${parsed.did}`);
  }

  const write = MiotCommandMapper.map(command, spec);
  options.beforeSend?.();
  const clientFactory = options.clientFactory ?? ((session, tp) => new MiCloudClient(session, tp));
  let sawExpired = false;
  let attemptCount = 0;

  for (const ownerId of owners) { const accountIdx = options.accounts.findIndex((acc) => acc.id === ownerId);
    if (accountIdx < 0) continue;
    const account = options.accounts[accountIdx]!;
    // A session the server already refused has no client-side refresh left: fail over to another
    // owning account instead of spending a request that can only 401 again.
    if (getAccountTokenStatus(account, Date.now(), options.storage).kind === "expired") {
      sawExpired = true;
      continue;
    }
    if (attemptCount > 0) { options.beforeSend?.(); }
    attemptCount += 1;
    const client = clientFactory(account.session, options.transport);
    try {
      // One attempt per account. Retrying this closure reused the same refused serviceToken, so a
      // write could reach the device twice (#6); recovery is a re-scan, which replaces the session.
      await (write.kind === "setProps" ? client.setProps(write.writes) : client.callAction(write.call));
      return { executedByAccountId: account.id };
    } catch (error) { if (error instanceof MiCloudError && error.kind === "sessionExpired") { sawExpired = true;
        markAccountSessionRejected(account.session, true, {
          isPrimary: accountIdx === 0,
          storage: options.storage,
        });
        continue;
      }
      throw error;
    }
  }

  throw sawExpired
    ? new MiCloudError("sessionExpired", "All owning Xiaomi account sessions have expired")
    : new MiCloudError("notLoggedIn", "No active Xiaomi account available for command");
}

export class MultiAccountMiCloudProvider implements HomeProvider {
  constructor(
    private readonly dependencies: {
      readonly accounts: readonly MiAccount[];
      readonly deviceOwners: Readonly<Record<string, readonly string[]>>;
      readonly specsByModel: Readonly<Record<string, MiotDeviceSpec>>;
      readonly devices: readonly SmartDevice[];
      readonly specResolver: Pick<MiotSpecResolver, "resolve">;
      readonly deviceForEntity: (entityId: string) => SmartDevice | undefined;
      readonly transport: HttpTransport;
      readonly storage?: Storage | null;
    },
  ) {}

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<boolean | null> {
    const parsed = parseMiotActionAddress(command.entityId) ?? parseMiotAddress(command.entityId);
    if (!parsed) {
      throw new Error(`Invalid MIoT entity address: ${command.entityId}`);
    }
    const device =
      this.dependencies.deviceForEntity(command.entityId) ??
      this.dependencies.devices.find(
        (item) => item.id === parsed.did || extractDeviceMiotCommandDids(item).includes(parsed.did),
      );
    if (!device) {
      throw new Error("无法找到指令对应的设备");
    }
    const spec =
      this.dependencies.specsByModel[device.model] ??
      (await this.dependencies.specResolver.resolve({
        did: device.id,
        name: device.name,
        model: device.model,
        isOnline: device.isOnline,
        specType: null,
      }));
    const write = MiotCommandMapper.map(command, spec);
    options.beforeSend?.();

    const mappedOwners = this.dependencies.deviceOwners[parsed.did] ?? [];
    const fallbackAccountId = device.accountId;
    const candidateIds =
      mappedOwners.length > 0
        ? mappedOwners
        : [
            ...(fallbackAccountId ? [fallbackAccountId] : []),
            ...this.dependencies.accounts.map((acc) => acc.id),
          ];
    let sawExpired = false;
    let attemptCount = 0;
    for (const ownerId of new Set(candidateIds)) {
      const accountIdx = this.dependencies.accounts.findIndex((acc) => acc.id === ownerId);
      if (accountIdx < 0) continue;
      const account = this.dependencies.accounts[accountIdx]!;
      // The refused credential is not worth another request; a re-scan replaces the stored session.
      if (getAccountTokenStatus(account, Date.now(), this.dependencies.storage).kind === "expired") {
        sawExpired = true;
        continue;
      }
      if (attemptCount > 0) {
        options.beforeSend?.();
      }
      attemptCount += 1;
      const client = new MiCloudClient(account.session, this.dependencies.transport);
      try {
        if (write.kind === "action") {
          await client.action(write.call);
          return null;
        }
        await client.setProps(write.writes);
        if (!options.readBackPower) return null;
        const power = write.writes.find((w) => typeof w.value === "boolean");
        if (!power) return null;
        let read: Map<string, unknown>;
        try {
          read = await client.getProps([power]);
        } catch (error) {
          throw new PowerReadBackError(error);
        }
        const isOn = readMiotPower(read.get(propKeyString(power)));
        if (isOn === null) throw new PowerReadBackError(new Error("未能读回设备状态"));
        return isOn;
      } catch (error) {
        if (error instanceof MiCloudError && error.kind === "sessionExpired") {
          sawExpired = true;
          markAccountSessionRejected(account.session, true, {
            isPrimary: accountIdx === 0,
            storage: this.dependencies.storage,
          });
          continue;
        }
        throw error;
      }
    }
    throw sawExpired
      ? new MiCloudError("sessionExpired", "All owning Xiaomi account sessions have expired")
      : new MiCloudError("notLoggedIn", "No active Xiaomi account available for command");
  }
}
