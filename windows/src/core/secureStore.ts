import { ASSISTANT_PROVIDER_PRESETS, assistantEndpointIdentity, inferAssistantPreset } from "./assistant/provider.js";
import { normalizeMiCloudRegion, type MiSession } from "./miCloudClient.js";

export const WIN32_CRED_MAX_BLOB_BYTES = 2560;

export type AssistantPresetCredentialName = `assistant_api_key_${string}`;
export type MiAccountCredentialName = `mi_session_${string}`;
export type SecureCredentialName =
  | "mi_session"
  | "ha_token"
  | "assistant_api_key"
  | AssistantPresetCredentialName
  | MiAccountCredentialName;

export function assistantApiKeyCredentialName(presetId: string): AssistantPresetCredentialName {
  return `assistant_api_key_${presetId}`;
}

export function normalizeMiCredentialSlotId(slotId: string): string {
  const cleaned = slotId
    .trim()
    .replace(/^mi:/i, "")
    .replace(/:/g, "_")
    .replace(/[^A-Za-z0-9_-]/g, "_")
    .slice(0, 48);
  if (cleaned.length === 0 || !/^[A-Za-z0-9_-]{1,48}$/.test(cleaned)) {
    throw new Error(`Invalid Xiaomi credential slot id: ${slotId}`);
  }
  return cleaned;
}

export function miAccountSessionCredentialName(slotId: string): MiAccountCredentialName {
  return `mi_session_${normalizeMiCredentialSlotId(slotId)}`;
}

const utf8CredentialEncoder = new TextEncoder();

export function credentialBlobByteLength(value: string): number {
  return utf8CredentialEncoder.encode(value).byteLength;
}

export function assertCredentialBlobWithinLimit(
  value: string,
  slotName: string = "mi_session",
): void {
  const bytes = credentialBlobByteLength(value);
  if (bytes > WIN32_CRED_MAX_BLOB_BYTES) {
    throw new Error(
      `Credential slot ${slotName} exceeds Win32 CRED_MAX_CREDENTIAL_BLOB_SIZE (${bytes} > ${WIN32_CRED_MAX_BLOB_BYTES} bytes)`,
    );
  }
}

export interface CredentialSnapshot {
  readonly miSession: MiSession | null;
  readonly haToken: string;
  readonly assistantApiKey: string;
  readonly assistantApiKeys?: Readonly<Record<string, string>>;
  readonly miAccountSessions?: Readonly<Record<string, MiSession>>;
}

export interface CredentialFields {
  readonly miSession?: MiSession | null;
  readonly haToken?: string;
  readonly openRouterApiKey?: string;
  readonly assistantBaseURL?: string;
  readonly assistantCustomKeyEndpoint?: string | null;
  readonly assistantKeyEndpoint?: string | null;
}

const CREDENTIAL_SETTINGS_FIELDS = ["miSession", "miAccounts", "haToken", "openRouterApiKey"] as const;

export function hasCredentials(credentials: CredentialSnapshot): boolean {
  if (credentials.miSession !== null || credentials.haToken !== "" || credentials.assistantApiKey !== "") {
    return true;
  }
  if (Object.keys(credentials.miAccountSessions ?? {}).length > 0) {
    return true;
  }
  return Object.values(credentials.assistantApiKeys ?? {}).some((value) => value.trim() !== "");
}

export function sanitizeSettingsForStorage<T extends object>(settings: T): Record<string, unknown> {
  const copy = { ...settings } as Record<string, unknown>;
  for (const field of CREDENTIAL_SETTINGS_FIELDS) delete copy[field];
  const cache = copy.cachedHAHome;
  if (cache && typeof cache === "object" && "home" in cache) {
    const home = cache.home;
    if (home && typeof home === "object" && "devices" in home && Array.isArray(home.devices)) {
      copy.cachedHAHome = {
        ...cache,
        home: {
          ...home,
          devices: home.devices.map((device: unknown) => {
            if (!device || typeof device !== "object" || !("kind" in device)) return device;
            const kind = device.kind;
            if (!kind || typeof kind !== "object" || !("kind" in kind) || kind.kind !== "camera") return device;
            return { ...device, kind: { ...kind, snapshotPath: null } };
          }),
        },
      };
    }
  }
  return copy;
}

export function parseMiSession(raw: unknown): MiSession | null {
  let value = raw;
  if (typeof raw === "string") {
    if (raw.trim() === "") return null;
    try {
      value = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const stringField = (key: string): string | null => {
    const field = record[key];
    return typeof field === "string" ? field : null;
  };
  const userId = stringField("userId");
  const ssecurity = stringField("ssecurity");
  const serviceToken = stringField("serviceToken");
  if (!userId || !ssecurity || !serviceToken) return null;
  const rawExpiresAt = record["expiresAt"];
  const expiresAt = typeof rawExpiresAt === "number" && Number.isFinite(rawExpiresAt) ? rawExpiresAt : undefined;
  return {
    userId,
    cUserId: stringField("cUserId") ?? "",
    ssecurity,
    serviceToken,
    passToken: "",
    region: normalizeMiCloudRegion(stringField("region")),
    ...(expiresAt !== undefined ? { expiresAt } : {}),
  };
}

export function serializeMiSession(session: MiSession): string {
  return JSON.stringify({
    userId: session.userId,
    cUserId: session.cUserId,
    ssecurity: session.ssecurity,
    serviceToken: session.serviceToken,
    region: session.region,
    ...(typeof session.expiresAt === "number" && Number.isFinite(session.expiresAt)
      ? { expiresAt: session.expiresAt }
      : {}),
  });
}

export function sessionWithoutPassToken(session: MiSession): MiSession {
  return {
    userId: session.userId,
    cUserId: session.cUserId,
    ssecurity: session.ssecurity,
    serviceToken: session.serviceToken,
    passToken: "",
    region: session.region,
    ...(typeof session.expiresAt === "number" && Number.isFinite(session.expiresAt)
      ? { expiresAt: session.expiresAt }
      : {}),
  };
}

export function credentialsFromSettings(
  settings: CredentialFields,
  existingKeys?: Readonly<Record<string, string>>
): CredentialSnapshot {
  const session = settings.miSession ? parseMiSession(settings.miSession) : null;
  const activePreset = inferAssistantPreset(settings.assistantBaseURL ?? "https://openrouter.ai/api/v1").id;
  const activeKey = settings.openRouterApiKey?.trim() ?? "";
  const assistantApiKeys: Record<string, string> = {};
  if (existingKeys) {
    for (const [presetId, value] of Object.entries(existingKeys)) {
      const trimmed = value.trim();
      if (trimmed !== "") assistantApiKeys[presetId] = trimmed;
    }
  }
  if (activeKey !== "") {
    assistantApiKeys[activePreset] = activeKey;
  } else if (activePreset === "custom") {
    const currentEndpoint = assistantEndpointIdentity(settings.assistantBaseURL ?? "");
    const boundCustomEndpoint = settings.assistantCustomKeyEndpoint ?? settings.assistantKeyEndpoint ?? null;
    if (boundCustomEndpoint === null || currentEndpoint === boundCustomEndpoint) {
      delete assistantApiKeys[activePreset];
    }
  } else {
    delete assistantApiKeys[activePreset];
  }
  return {
    miSession: session ? sessionWithoutPassToken(session) : null,
    haToken: settings.haToken?.trim() ?? "",
    assistantApiKey: activeKey,
    assistantApiKeys,
  };
}

export type SecureInvoke = <T>(cmd: string, args: Record<string, unknown>) => Promise<T | null>;

function tauriInvoke<T>(cmd: string, args: Record<string, unknown>): Promise<T | null> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return Promise.resolve(null);
  return invoke<T>(cmd, args);
}

export async function secureStoreGet(
  name: SecureCredentialName,
  invoke: SecureInvoke = tauriInvoke
): Promise<string | null> {
  const value = await invoke<string | null>("secure_store_get", { name });
  return typeof value === "string" ? value : null;
}

export async function secureStoreSet(
  name: SecureCredentialName,
  value: string,
  invoke: SecureInvoke = tauriInvoke
): Promise<void> {
  await invoke<void>("secure_store_set", { name, value });
}

export async function secureStoreDelete(
  name: SecureCredentialName,
  invoke: SecureInvoke = tauriInvoke
): Promise<void> {
  await invoke<void>("secure_store_delete", { name });
}

export class CredentialVault {
  private readonly known = new Map<SecureCredentialName, string>();
  private opChain: Promise<void> = Promise.resolve();

  constructor(private readonly invoke: SecureInvoke = tauriInvoke) {}

  private serialize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.opChain.then(work, work);
    this.opChain = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }

  async load(activePresetId = "openrouter_jev", legacyKeyEndpoint?: string | null): Promise<CredentialSnapshot> {
    return this.serialize(() => this.loadInternal(activePresetId, legacyKeyEndpoint));
  }

  private async loadInternal(
    activePresetId: string,
    legacyKeyEndpoint?: string | null,
  ): Promise<CredentialSnapshot> {
    const presetIds = ASSISTANT_PROVIDER_PRESETS.map((preset) => preset.id);
    const [sessionRaw, haToken, legacyAssistantKey, ...presetValues] = await Promise.all([
      secureStoreGet("mi_session", this.invoke).catch(() => null),
      secureStoreGet("ha_token", this.invoke).catch(() => null),
      secureStoreGet("assistant_api_key", this.invoke).catch(() => null),
      ...presetIds.map((id) => secureStoreGet(assistantApiKeyCredentialName(id), this.invoke).catch(() => null)),
    ]);
    const miSession = parseMiSession(sessionRaw);
    const assistantApiKeys: Record<string, string> = {};
    for (let i = 0; i < presetIds.length; i += 1) {
      const presetId = presetIds[i]!;
      const value = presetValues[i]?.trim() ?? "";
      this.remember(assistantApiKeyCredentialName(presetId), value);
      if (value !== "") assistantApiKeys[presetId] = value;
    }
    const legacyTrimmed = legacyAssistantKey?.trim() ?? "";
    this.remember("assistant_api_key", legacyTrimmed);
    if (legacyTrimmed !== "") {
      const ownerPreset =
        legacyKeyEndpoint !== undefined
          ? legacyKeyEndpoint && legacyKeyEndpoint.trim() !== ""
            ? inferAssistantPreset(`https://${legacyKeyEndpoint.trim()}`).id
            : "openrouter_jev"
          : activePresetId;
      const targetSlot = assistantApiKeyCredentialName(ownerPreset);
      if (assistantApiKeys[ownerPreset]) {
        try {
          await secureStoreDelete("assistant_api_key", this.invoke);
          this.remember("assistant_api_key", "");
        } catch {
          this.remember("assistant_api_key", legacyTrimmed);
        }
      } else {
        assistantApiKeys[ownerPreset] = legacyTrimmed;
        let wroteTarget = false;
        try {
          await secureStoreSet(targetSlot, legacyTrimmed, this.invoke);
          this.remember(targetSlot, legacyTrimmed);
          wroteTarget = true;
        } catch {
          this.remember(targetSlot, "");
        }
        if (wroteTarget) {
          try {
            await secureStoreDelete("assistant_api_key", this.invoke);
            this.remember("assistant_api_key", "");
          } catch {
            this.remember("assistant_api_key", legacyTrimmed);
          }
        }
      }
    }
    const snapshot: CredentialSnapshot = {
      miSession,
      haToken: haToken ?? "",
      assistantApiKey: assistantApiKeys[activePresetId] ?? "",
      assistantApiKeys,
    };
    this.remember("mi_session", miSession ? serializeMiSession(miSession) : "");
    this.remember("ha_token", snapshot.haToken);
    return snapshot;
  }

    async persist(credentials: CredentialSnapshot): Promise<void> {
    return this.serialize(async () => {
      const primarySerialized = credentials.miSession ? serializeMiSession(credentials.miSession) : "";
      if (primarySerialized !== "") {
        assertCredentialBlobWithinLimit(primarySerialized, "mi_session");
      }
      const keyWrites =
        credentials.assistantApiKeys !== undefined
          ? ASSISTANT_PROVIDER_PRESETS.map((preset) =>
              this.sync(
                assistantApiKeyCredentialName(preset.id),
                credentials.assistantApiKeys?.[preset.id]?.trim() ?? ""
              )
            )
          : [this.sync(assistantApiKeyCredentialName("openrouter_jev"), credentials.assistantApiKey)];
      const accountSlotWrites: Promise<void>[] = [];
      if (credentials.miAccountSessions !== undefined) {
        for (const [slotId, slotSession] of Object.entries(credentials.miAccountSessions)) {
          const slotName = miAccountSessionCredentialName(slotId);
          const serialized = serializeMiSession(sessionWithoutPassToken(slotSession));
          assertCredentialBlobWithinLimit(serialized, slotName);
          accountSlotWrites.push(this.sync(slotName, serialized));
        }
      }
      const results = await Promise.allSettled([
        this.sync("mi_session", primarySerialized),
        this.sync("ha_token", credentials.haToken),
        ...keyWrites,
        ...accountSlotWrites,
      ]);
      const failure = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
      if (failure) throw failure.reason;
      if (credentials.assistantApiKeys !== undefined) {
        await this.sync("assistant_api_key", "");
      }
    });
  }

  hasLegacyAssistantKey(): boolean {
    return (this.known.get("assistant_api_key") ?? "") !== "";
  }

    async loadPrimaryMiSession(): Promise<MiSession | null> {
    return this.serialize(async () => {
      const raw = await secureStoreGet("mi_session", this.invoke).catch(() => null);
      const parsed = parseMiSession(raw);
      this.remember("mi_session", parsed ? serializeMiSession(parsed) : "");
      return parsed;
    });
  }

    async savePrimaryMiSession(session: MiSession | null): Promise<void> {
    return this.serialize(async () => {
      if (session === null) {
        await this.sync("mi_session", "");
        return;
      }
      const serialized = serializeMiSession(sessionWithoutPassToken(session));
      assertCredentialBlobWithinLimit(serialized, "mi_session");
      await this.sync("mi_session", serialized);
    });
  }

    async loadMiAccountSlot(slotId: string): Promise<MiSession | null> {
    return this.serialize(async () => {
      const slotName = miAccountSessionCredentialName(slotId);
      const raw = await secureStoreGet(slotName, this.invoke).catch(() => null);
      const parsed = parseMiSession(raw);
      this.remember(slotName, parsed ? serializeMiSession(parsed) : "");
      return parsed;
    });
  }

    async loadMiAccountSlots(slotIds: readonly string[]): Promise<Record<string, MiSession>> {
    if (slotIds.length === 0) return {};
    return this.serialize(async () => {
      const uniqueIds = [...new Set(slotIds.map((id) => normalizeMiCredentialSlotId(id)))];
      const raws = await Promise.all(
        uniqueIds.map((id) => secureStoreGet(miAccountSessionCredentialName(id), this.invoke).catch(() => null)),
      );
      const out: Record<string, MiSession> = {};
      for (let i = 0; i < uniqueIds.length; i += 1) {
        const slotId = uniqueIds[i]!;
        const slotName = miAccountSessionCredentialName(slotId);
        const parsed = parseMiSession(raws[i]);
        this.remember(slotName, parsed ? serializeMiSession(parsed) : "");
        if (parsed) out[slotId] = parsed;
      }
      return out;
    });
  }

    async saveMiAccountSlot(slotId: string, session: MiSession): Promise<void> {
    return this.serialize(async () => {
      const normalizedSlotId = normalizeMiCredentialSlotId(slotId);
      const slotName = miAccountSessionCredentialName(normalizedSlotId);
      const serialized = serializeMiSession(sessionWithoutPassToken(session));
      assertCredentialBlobWithinLimit(serialized, slotName);
      await this.sync(slotName, serialized);
    });
  }

    async deleteMiAccountSlot(slotId: string): Promise<void> {
    return this.serialize(async () => {
      const slotName = miAccountSessionCredentialName(slotId);
      await secureStoreDelete(slotName, this.invoke);
      this.known.set(slotName, "");
    });
  }

    async deleteMiSession(extraSlotIds: readonly string[] = []): Promise<void> {
    return this.serialize(async () => {
      const indexKeys = ["menumijia.windows.miAccountsIndex.v1", "menumijia.miAccountsIndex.v1"] as const;
      const expiredKeys = ["menumijia.windows.miAccountsExpired.v1", "menumijia.miAccountsExpired.v1"] as const;
      const slots = new Set<SecureCredentialName>(["mi_session"]);
      for (const key of this.known.keys()) {
        if (key.startsWith("mi_session_")) slots.add(key);
      }
      try {
        if (typeof localStorage !== "undefined") {
          for (const indexKey of indexKeys) {
            const rawIndex = localStorage.getItem(indexKey);
            if (!rawIndex) continue;
            const parsed: unknown = JSON.parse(rawIndex);
            if (!Array.isArray(parsed)) continue;
            for (const item of parsed) {
              const slotId = item && typeof item === "object" ? (item as Record<string, unknown>)["slotId"] : null;
              if (typeof slotId === "string" && slotId.trim() !== "") {
                slots.add(miAccountSessionCredentialName(slotId));
              }
            }
          }
        }
      } catch {
      }
      for (const slotId of extraSlotIds) {
        if (slotId.trim() !== "") slots.add(miAccountSessionCredentialName(slotId));
      }
      const slotList = [...slots];
      const results = await Promise.allSettled(slotList.map((slot) => secureStoreDelete(slot, this.invoke)));
      const failure = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
      if (failure) throw failure.reason;
      for (const slot of slotList) {
        this.known.set(slot, "");
      }
      try {
        if (typeof localStorage !== "undefined") {
          for (const k of indexKeys) localStorage.removeItem(k);
          for (const k of expiredKeys) localStorage.removeItem(k);
        }
      } catch {
      }
    });
  }

  private remember(name: SecureCredentialName, value: string): void {
    this.known.set(name, value);
  }

  private async sync(name: SecureCredentialName, value: string): Promise<void> {
    if (this.known.get(name) === value) return;
    if (value !== "") {
      await secureStoreSet(name, value, this.invoke);
    } else if (this.known.get(name)) {
      await secureStoreDelete(name, this.invoke);
    }
    this.known.set(name, value);
  }
}
