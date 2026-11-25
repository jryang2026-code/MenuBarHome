import { defaultStorage } from "./pollingPolicy.js";

export const CANONICAL_DEVICE_REGISTRY_STORAGE_KEY = "menumijia.windows.canonicalDeviceIds.v1";
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
export const CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS = [
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY + ".1.bak",
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY + ".2.bak",
] as const;

interface RegistryState {
  readonly assignments: Readonly<Record<string, string>>;
  readonly orphanedAt?: Readonly<Record<string, number>>;
  readonly explicitlyDeleted?: readonly string[];
}

export interface NativeCanonicalRegistry {
  load(): Promise<{ registry: RegistryState | null; revision: number }>;
  save(registry: RegistryState, revision: number): Promise<boolean>;
}

export function nativeCanonicalRegistry(): NativeCanonicalRegistry | undefined {
  const native = typeof window === "undefined" ? undefined : window.__TAURI_INTERNALS__;
  if (!native?.metadata || !native.invoke) return undefined;
  return {
    load: () => native.invoke("load_canonical_registry"),
    save: (registry, revision) => native.invoke("save_canonical_registry", { registry, revision }),
  };
}

export async function clearNativeCanonicalRegistry(): Promise<void> {
  if (nativeCanonicalRegistry()) await window.__TAURI_INTERNALS__!.invoke("clear_canonical_registry");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.entries(value).every(([key, item]) => key && typeof item === "string" && item);
}

function isTimestampRecord(value: unknown): value is Record<string, number> {
  return isRecord(value) && Object.values(value).every((item) =>
    typeof item === "number" && Number.isSafeInteger(item) && item >= 0);
}

function readCopy(storage: Storage, key: string): CanonicalDeviceRegistry | null {
  try {
    const raw = storage.getItem(key);
    if (raw === null) return null;
    const value: unknown = JSON.parse(raw);
    if (isStringRecord(value)) return new CanonicalDeviceRegistry(value);
    if (!isRecord(value) || !isStringRecord(value.assignments)) return null;
    const orphanedAt = value.orphanedAt;
    const explicitlyDeleted = value.explicitlyDeleted;
    if (orphanedAt !== undefined && !isTimestampRecord(orphanedAt)) return null;
    if (explicitlyDeleted !== undefined &&
        (!Array.isArray(explicitlyDeleted) || !explicitlyDeleted.every((id) => typeof id === "string" && id))) return null;
    return new CanonicalDeviceRegistry(value.assignments, orphanedAt, explicitlyDeleted);
  } catch {
    return null;
  }
}

export class CanonicalDeviceRegistry {
  readonly assignments: Record<string, string>;
  private readonly orphanedAt: Map<string, number>;
  private readonly explicitlyDeleted: Set<string>;

  constructor(
    assignments: Readonly<Record<string, string>> = {},
    orphanedAt: Readonly<Record<string, number>> = {},
    explicitlyDeleted: readonly string[] = [],
  ) {
    this.assignments = { ...assignments };
    this.orphanedAt = new Map(Object.entries(orphanedAt));
    this.explicitlyDeleted = new Set(explicitlyDeleted);
  }

  canonicalId(forKeys: readonly string[], allowOrphans = true): string | null {
    for (const key of forKeys) {
      const id = this.assignments[key];
      if (typeof id === "string" && id && !this.explicitlyDeleted.has(id) &&
          (allowOrphans || !this.orphanedAt.has(id))) return id;
    }
    return null;
  }

  assign(canonicalId: string, toKeys: readonly string[]): void {
    if (!canonicalId || this.explicitlyDeleted.has(canonicalId)) return;
    for (const key of toKeys) if (key) this.assignments[key] = canonicalId;
  }

  // Preferences keep their storage owners. Reusing their card ID restores them together.
  reconcile(presentIds: ReadonlySet<string>, nowMs: number): void {
    const assignedIds = new Set(Object.values(this.assignments));
    for (const id of this.orphanedAt.keys()) {
      if (presentIds.has(id) || !assignedIds.has(id)) this.orphanedAt.delete(id);
    }
    for (const id of assignedIds) {
      if (!presentIds.has(id) && !this.orphanedAt.has(id)) this.orphanedAt.set(id, nowMs);
    }
    this.purge(nowMs);
  }

  purge(nowMs: number): void {
    const expired = new Set<string>();
    for (const [id, timestamp] of this.orphanedAt) {
      if (nowMs - timestamp >= RETENTION_MS) {
        expired.add(id);
        this.orphanedAt.delete(id);
      }
    }
    for (const [key, id] of Object.entries(this.assignments)) {
      if (expired.has(id)) delete this.assignments[key];
    }
  }

  forget(canonicalId: string): void {
    if (!canonicalId) return;
    this.explicitlyDeleted.add(canonicalId);
    this.orphanedAt.delete(canonicalId);
    for (const [key, id] of Object.entries(this.assignments)) {
      if (id === canonicalId) delete this.assignments[key];
    }
  }

  clone(): CanonicalDeviceRegistry {
    return new CanonicalDeviceRegistry(this.assignments, Object.fromEntries(this.orphanedAt), [...this.explicitlyDeleted]);
  }

  state(): RegistryState {
    return {
      assignments: { ...this.assignments },
      ...(this.orphanedAt.size ? { orphanedAt: Object.fromEntries(this.orphanedAt) } : {}),
      ...(this.explicitlyDeleted.size ? { explicitlyDeleted: [...this.explicitlyDeleted].sort() } : {}),
    };
  }

  static load(storage: Storage | null = defaultStorage()): CanonicalDeviceRegistry {
    if (storage) {
      for (const key of [CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, ...CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS]) {
        const registry = readCopy(storage, key);
        if (registry) return registry;
      }
    }
    return new CanonicalDeviceRegistry();
  }

  save(storage: Storage | null = defaultStorage()): void {
    if (!storage) return;
    const current = JSON.stringify(this.state());
    try {
      const primary = readCopy(storage, CANONICAL_DEVICE_REGISTRY_STORAGE_KEY);
      if (primary ? JSON.stringify(primary.state()) === current : current === '{"assignments":{}}' &&
          storage.getItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY) === null &&
          CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS.every((key) => storage.getItem(key) === null)) return;

      const valid = [primary, ...CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS.map((key) => readCopy(storage, key))]
        .filter((copy): copy is CanonicalDeviceRegistry => copy !== null);
      for (let index = CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS.length - 1; index >= 0; index -= 1) {
        const previous = valid[index];
        if (!previous) continue;
        for (const id of this.explicitlyDeleted) previous.forget(id);
        storage.setItem(CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS[index]!, JSON.stringify(previous.state()));
      }
      storage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, current);
    } catch {
      // The in-memory registry stays usable and the next save can retry.
    }
  }
}
