import { discoverMiHome } from "./miCloud/discovery.js";
import { PowerReadBackError, type ExecuteOptions, type HomeProvider } from "./homeProvider.js";
import { readMiotPower } from "./models.js";
import { currentLanguage,
  resolveLanguage,
  type AppLanguage,
  type LanguagePreference,
} from "./i18n.js";
import { sha256 } from "./miCloudCrypto.js";
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
import { clearPersistedMiSessionExpired,
  isPersistedMiSessionExpired,
  isXiaomiRateLimitError,
  miSessionFingerprint,
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

function tr3(zhHans: string,
  zhHant: string,
  en: string,
  params?: Readonly<Record<string, string | number>>,
  preference?: LanguagePreference,
): string { const lang: AppLanguage = preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : resolveLanguage(currentLanguage(), []);
  const template = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole,
  );
}

const utf8Encoder = new TextEncoder();

function bytesToHex(bytes: Uint8Array): string { let out = "";
  for (let i = 0; i < bytes.length; i += 1) { out += (bytes[i] ?? 0).toString(16).padStart(2, "0");
  }
  return out;
}

function defaultStorage(): Storage | null { try { return typeof localStorage !== "undefined" ? localStorage : null;
  } catch { return null;
  }
}

export const MI_ACCOUNTS_INDEX_STORAGE_KEY = "menumijia.windows.miAccountsIndex.v1";
export const MI_ACCOUNTS_EXPIRED_STORAGE_KEY = "menumijia.windows.miAccountsExpired.v1";

export function miAccountId(session: Pick<MiSession, "userId" | "region">): string {
  const region = normalizeMiCloudRegion(session.region);
  const rawKey = `${region}:${session.userId.trim()}`;
  const digest = sha256(utf8Encoder.encode(rawKey));
  return `mi:${region}:${bytesToHex(digest.subarray(0, 8))}`;
}

export function miAccountSlotId(accountIdOrSession: string | Pick<MiSession, "userId" | "region">,
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

interface PersistedAccountExpiredRecord { readonly fingerprint: string;
  readonly expiredAtMs: number;
}

function readPersistedAccountExpiryMap(storage: Storage | null,
): Record<string, PersistedAccountExpiredRecord> { if (!storage) return {};
  try { const raw = storage.getItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: Record<string, PersistedAccountExpiredRecord> = {};
    for (const [accountId, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      const rec = value as Record<string, unknown>;
      if (typeof rec["fingerprint"] === "string" && typeof rec["expiredAtMs"] === "number") { out[accountId] = {
          fingerprint: rec["fingerprint"],
          expiredAtMs: rec["expiredAtMs"],
        };
      }
    }
    return out;
  } catch { return {};
  }
}

function writePersistedAccountExpiryMap(storage: Storage | null,
  map: Readonly<Record<string, PersistedAccountExpiredRecord>>,
): void { if (!storage) return;
  try { if (Object.keys(map).length === 0) { storage.removeItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY);
    } else { storage.setItem(MI_ACCOUNTS_EXPIRED_STORAGE_KEY, JSON.stringify(map));
    }
  } catch {
  }
}

export function isAccountSessionRejected(session: MiSession | null | undefined,
  storage: Storage | null = defaultStorage(),
): boolean { if (!session) return false;
  const accountId = miAccountId(session);
  const fp = miSessionFingerprint(session);
  const map = readPersistedAccountExpiryMap(storage);
  if (map[accountId]?.fingerprint === fp) return true;
  return isPersistedMiSessionExpired(session, storage);
}

export function markAccountSessionRejected(session: MiSession | null | undefined,
  expired: boolean,
  options: { readonly isPrimary?: boolean;
    readonly storage?: Storage | null;
    readonly nowMs?: number;
  } = {},
): void { if (!session) return;
  const storage = options.storage !== undefined ? options.storage : defaultStorage();
  const nowMs = options.nowMs ?? Date.now();
  const accountId = miAccountId(session);
  const map = readPersistedAccountExpiryMap(storage);
  if (expired) { map[accountId] = {
      fingerprint: miSessionFingerprint(session),
      expiredAtMs: nowMs,
    };
    if (options.isPrimary) { persistMiSessionExpired(session, true, storage, nowMs);
    }
  } else { delete map[accountId];
    if (options.isPrimary || isPersistedMiSessionExpired(session, storage)) { clearPersistedMiSessionExpired(storage);
    }
  }
  writePersistedAccountExpiryMap(storage, map);
}

export function getAccountTokenStatus(accountOrSession: MiAccount | MiSession,
  nowMs = Date.now(),
  storage: Storage | null = defaultStorage(),
  warningLeadMs = MI_SESSION_WARNING_LEAD_MS,
): MiAccountTokenStatus { const session = "session" in accountOrSession ? accountOrSession.session : accountOrSession;
  const accountId = miAccountId(session);
  const map = readPersistedAccountExpiryMap(storage);
  const fp = miSessionFingerprint(session);
  const rejected = map[accountId];
  if (rejected?.fingerprint === fp) { return { kind: "expired", source: "rejected", expiredAtMs: rejected.expiredAtMs };
  }
  if (isPersistedMiSessionExpired(session, storage)) { return { kind: "expired", source: "rejected" };
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

export interface MiAccountIndexEntry { readonly id: string;
  readonly slotId: string;
  readonly region: string;
  readonly maskedUserId: string;
}

export function hasSecondaryMiAccountsInIndex(storage: Storage | null = defaultStorage(),
): boolean { if (!storage) return false;
  try { const raw = storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
    if (!raw) return false;
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) && parsed.length > 1;
  } catch { return false;
  }
}

export function readAccountIndex(storage: Storage | null = defaultStorage()): MiAccountIndexEntry[] { if (!storage) return [];
  try { const raw = storage.getItem(MI_ACCOUNTS_INDEX_STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const out: MiAccountIndexEntry[] = [];
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
  } catch { return [];
  }
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

export class MiAccountsStore { private cachedAccounts: MiAccount[] = [];
  private loaded = false;
  private lastWroteIndexToStorage = false;

  constructor(private readonly vault: CredentialVault = new CredentialVault(),
    private readonly storage: Storage | null = defaultStorage(),
  ) {}

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

  primarySession(): MiSession | null { this.syncExternalRevocation();
    return this.cachedAccounts[0]?.session ?? null;
  }

    async load(): Promise<MiAccount[]> { this.syncExternalRevocation();
    const index = readAccountIndex(this.storage);
    let primaryReadFailed = false;
    let primarySession: MiSession | null = null;
    try {
      primarySession = await this.vault.loadPrimaryMiSession();
      if (this.vault.didLastPrimaryMiSessionReadFail?.() === true) primaryReadFailed = true;
    } catch {
      primaryReadFailed = true;
    }
    const primaryAccount = primarySession ? makeMiAccount(primarySession) : null;
    if (!primaryReadFailed && this.storage !== null && index.length === 0 && this.cachedAccounts.length > 0) {
      this.cachedAccounts = [];
    }

    const secondarySlotIds: string[] = [];
    for (const entry of index) { if (primaryAccount && entry.id === primaryAccount.id) continue;
      secondarySlotIds.push(entry.slotId);
    }
    for (const mem of this.cachedAccounts) { if (primaryAccount && mem.id === primaryAccount.id) continue;
      if (!secondarySlotIds.includes(mem.slotId)) { secondarySlotIds.push(mem.slotId);
      }
    }

    let slotsReadFailed = false;
    let loadedSlots: Record<string, MiSession> = {};
    try {
      loadedSlots = await this.vault.loadMiAccountSlots(secondarySlotIds);
      if (this.vault.didLastMiAccountSlotsReadFail?.() === true) slotsReadFailed = true;
    } catch {
      slotsReadFailed = true;
    }
    const ordered: MiAccount[] = [];
    const seenIds = new Set<string>();

    if (primaryAccount) { ordered.push(primaryAccount);
      seenIds.add(primaryAccount.id);
    } else if (primaryReadFailed && this.cachedAccounts.length > 0) {
      const cachedPrimary = this.cachedAccounts[0]!;
      ordered.push(cachedPrimary);
      seenIds.add(cachedPrimary.id);
    }

    const candidateOrder = [
      ...index.map((entry) => entry.slotId),
      ...secondarySlotIds.filter((slot) => !index.some((entry) => entry.slotId === slot)),
    ];
    for (const slotId of candidateOrder) { const slotSession = loadedSlots[slotId];
      if (!slotSession) continue;
      const account = makeMiAccount(slotSession);
      if (seenIds.has(account.id)) {
        if (!primaryReadFailed && !slotsReadFailed) {
          await this.vault.deleteMiAccountSlot(slotId).catch(() => {});
        }
        continue;
      }
      seenIds.add(account.id);
      ordered.push(account);
    }

    if (!primaryAccount && !primaryReadFailed && ordered.length > 0) { const promoted = ordered[0]!;
      await this.vault.savePrimaryMiSession(promoted.session);
      await this.vault.deleteMiAccountSlot(promoted.slotId).catch(() => {});
    }

    this.cachedAccounts = ordered;
    this.loaded = true;
    if (!primaryReadFailed && !slotsReadFailed) {
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, ordered);
    }
    return [...ordered];
  }

    async upsertAccount(rawSession: MiSession): Promise<{ readonly accounts: MiAccount[];
    readonly account: MiAccount;
    readonly added: boolean;
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

    if (!this.loaded) { await this.load();
    }

    const existingIdx = this.cachedAccounts.findIndex((item) => item.id === account.id);
    if (existingIdx === 0) { const prevFp = miSessionFingerprint(this.cachedAccounts[0]!.session);
      await this.vault.savePrimaryMiSession(account.session);
      if (prevFp !== miSessionFingerprint(account.session)) { markAccountSessionRejected(account.session, false, {
          isPrimary: true,
          storage: this.storage,
        });
      }
      this.cachedAccounts = [account, ...this.cachedAccounts.slice(1)];
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
      return { accounts: [...this.cachedAccounts], account, added: false };
    }

    if (existingIdx > 0) { const prevFp = miSessionFingerprint(this.cachedAccounts[existingIdx]!.session);
      await this.vault.saveMiAccountSlot(account.slotId, account.session);
      if (prevFp !== miSessionFingerprint(account.session)) { markAccountSessionRejected(account.session, false, {
          isPrimary: false,
          storage: this.storage,
        });
      }
      const next = [...this.cachedAccounts];
      next[existingIdx] = account;
      this.cachedAccounts = next;
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
      return { accounts: [...this.cachedAccounts], account, added: false };
    }

    if (this.cachedAccounts.length === 0) { await this.vault.savePrimaryMiSession(account.session);
      markAccountSessionRejected(account.session, false, {
        isPrimary: true,
        storage: this.storage,
      });
      this.cachedAccounts = [account];
      this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
      return { accounts: [...this.cachedAccounts], account, added: true };
    }

    await this.vault.saveMiAccountSlot(account.slotId, account.session);
    markAccountSessionRejected(account.session, false, {
      isPrimary: false,
      storage: this.storage,
    });
    this.cachedAccounts = [...this.cachedAccounts, account];
    this.lastWroteIndexToStorage = writeAccountIndex(this.storage, this.cachedAccounts);
    return { accounts: [...this.cachedAccounts], account, added: true };
  }

    async removeAccount(accountId: string,
    selectedHomeId?: string | null,
  ): Promise<{ readonly accounts: MiAccount[];
    readonly primarySession: MiSession | null;
    readonly resetSelectedHome: boolean;
  }> { if (!this.loaded) { await this.load();
    }
    const idx = this.cachedAccounts.findIndex((item) => item.id === accountId);
    if (idx < 0) { return {
        accounts: [...this.cachedAccounts],
        primarySession: this.primarySession(),
        resetSelectedHome: false,
      };
    }

    const removed = this.cachedAccounts[idx]!;
    const resetSelectedHome = Boolean(selectedHomeId &&
        (MiAccountScope.isOwned(selectedHomeId, accountId) ||
          (MiAccountScope.owner(selectedHomeId) === null && idx === 0)),
    );

    const remaining = this.cachedAccounts.filter((item) => item.id !== accountId);
    if (idx === 0) { if (remaining.length === 0) { await this.vault.deleteMiSession();
      } else { const promoted = remaining[0]!;
        await this.vault.savePrimaryMiSession(promoted.session);
        await this.vault.deleteMiAccountSlot(promoted.slotId);
      }
    } else { await this.vault.deleteMiAccountSlot(removed.slotId);
    }

    markAccountSessionRejected(removed.session, false, {
      isPrimary: idx === 0 && remaining.length === 0,
      storage: this.storage,
    });
    this.cachedAccounts = remaining;
    this.lastWroteIndexToStorage = writeAccountIndex(this.storage, remaining);
    return {
      accounts: [...remaining],
      primarySession: remaining[0]?.session ?? null,
      resetSelectedHome,
    };
  }

    async clearAll(): Promise<void> { if (!this.loaded) { await this.load();
    }
    const index = readAccountIndex(this.storage);
    const slotIds = new Set<string>([
      ...this.cachedAccounts.map((acc) => acc.slotId),
      ...index.map((entry) => entry.slotId),
    ]);
    await this.vault.deleteMiSession([...slotIds]);
    this.cachedAccounts = [];
    this.loaded = true;
    this.lastWroteIndexToStorage = writeAccountIndex(this.storage, []);
    writePersistedAccountExpiryMap(this.storage, {});
    clearPersistedMiSessionExpired(this.storage);
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

export function stampAccountSnapshot(home: SynthesizedHome,
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

export function extractDeviceMiotCommandDids(device: SmartDevice,
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

export function aggregateAccountConnectionStatus(accounts: readonly MiAccount[],
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
  const seenPhysicalDids = new Set<string>();
  const readingIds = new Set<string>();
  const sceneIds = new Set<string>();
  const homeIds = new Set<string>();
  const facetsByDevice: Record<string, readonly FacetControl[]> = {};
  const lightGroupOwners = new Map<string, string>();
  const ownersMutable: Record<string, string[]> = {};
  const accountStatuses: Record<string, ConnectionStatus> = {};
  const accountTokenStatuses: Record<string, MiAccountTokenStatus> = {};
  const rawDevicesByAccount: Record<string, readonly MiDeviceRecord[]> = {};
  const allDevicesByAccount: Record<string, readonly MiDeviceRecord[]> = {};
  const allRoomsByAccount: Record<string, readonly MiRoom[]> = {};
  const specsByModel: Record<string, MiotDeviceSpec> = {};

  for (const account of accounts) { const child = children[account.id];
    if (!child) continue;
    accountStatuses[account.id] = child.status;
    accountTokenStatuses[account.id] = child.tokenStatus;
    rawDevicesByAccount[account.id] = child.rawDevices;
    allDevicesByAccount[account.id] = child.allDevices;
    allRoomsByAccount[account.id] = child.allRooms;
    for (const [model, spec] of Object.entries(child.specs)) { if (!specsByModel[model]) specsByModel[model] = spec;
    }

    const childFacets = child.home.deviceFacets ?? {};
    for (const device of child.home.devices) {
      const cmdDids = extractDeviceMiotCommandDids(device, childFacets[device.id] ?? []);
      for (const key of [device.id, ...cmdDids]) { const list = (ownersMutable[key] ??= []);
        if (!list.includes(account.id)) list.push(account.id);
      }
    }

    for (const room of child.home.rooms) { if (!roomIds.has(room.id)) { roomIds.add(room.id);
        rooms.push(room);
      }
    }

    for (const device of child.home.devices) { const baseDid = device.id;
      if (deviceIds.has(device.id) || seenPhysicalDids.has(baseDid)) continue;
      deviceIds.add(device.id);
      seenPhysicalDids.add(baseDid);
      devices.push(device);
      const facets = childFacets[device.id];
      if (facets && facets.length > 0) { facetsByDevice[device.id] = facets;
      }
    }

    for (const [memberDid, groupDid] of child.lightGroupOwners) { if (!lightGroupOwners.has(memberDid)) {
        lightGroupOwners.set(memberDid, groupDid);
      }
    }

    for (const reading of child.home.environmentReadings) {
      if (!readingIds.has(reading.id) && deviceIds.has(reading.id)) { readingIds.add(reading.id);
        readings.push(reading);
      }
    }

    for (const scene of child.home.scenes) { if (!sceneIds.has(scene.id)) { sceneIds.add(scene.id);
        scenes.push(scene);
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

export function getAccountRateLimitBackoffUntilMs(
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

export interface RefreshMiAccountsOptions {
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
}

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
      const [specs, membersByGroup] = await Promise.all([
        specResolver.resolveForDevices(filtered.devices),
        groupDids.length > 0
          ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
          : Promise.resolve(new Map<string, string[]>()),
      ]);

      const propKeys = collectAccountMiotPropKeys(filtered.devices, specs);
      const values = propKeys.length > 0
          ? await client.getProps(propKeys)
          : new Map<string, unknown>();

      const rawHome = MiotSynthesizer.synthesize(filtered.devices,
        filtered.rooms,
        specs,
        values,
      );
      const rawHomes = buildHomeOptionsFromMiRooms(discovered.rooms);
      const stamped = stampAccountSnapshot(rawHome, rawHomes, account, namespaceIds);

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
    if (attemptCount > 0) { options.beforeSend?.(); }
    attemptCount += 1;
    const account = options.accounts[accountIdx]!;
    const client = clientFactory(account.session, options.transport);
    try { if (write.kind === "setProps") { await client.setProps(write.writes);
      } else { await client.callAction(write.call);
      }
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
      if (attemptCount > 0) {
        options.beforeSend?.();
      }
      attemptCount += 1;
      const account = this.dependencies.accounts[accountIdx]!;
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
