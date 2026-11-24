import type { SmartDevice } from "./models.js";

export type CameraEventKind = "doorbell" | "motion" | "person" | "package";

export interface CameraEvent {
  readonly id: string;
  readonly cameraID: string;
  readonly kind: CameraEventKind;
  readonly timestamp: string;
  /** Relative filename owned by the local store, never a URL or credential. */
  readonly snapshotFile: string | null;
}

export interface CameraEventPersistence {
  load(): Promise<readonly unknown[]>;
  record(input: {
    readonly cameraID: string;
    readonly kind: CameraEventKind;
    readonly timestampMs: number;
    readonly snapshotBase64?: string | null;
  }): Promise<unknown>;
  attachSnapshot(eventId: string, snapshotBase64: string): Promise<unknown>;
  readSnapshot(snapshotFile: string): Promise<string | null>;
  clear(): Promise<void>;
}

export interface CameraStillWallTile {
  readonly id: string;
  readonly name: string;
  readonly isOnline: boolean;
  readonly snapshotDataUrl: string | null;
  readonly hasEvent: boolean;
}

export interface CameraStillWallRenderState {
  readonly tiles: readonly CameraStillWallTile[];
}

export const CAMERA_EVENT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const CAMERA_EVENT_LIMIT = 500;
export const CAMERA_STILL_WALL_LIMIT = 4;
export const CAMERA_STILL_REFRESH_COOLDOWN_MS = 60_000;
export const CAMERA_STILL_GLOBAL_GAP_MS = 2_500;
const MAX_SNAPSHOT_CACHE_ENTRIES = 32;

const ALLOWED_KINDS: ReadonlySet<string> = new Set<CameraEventKind>([
  "doorbell",
  "motion",
  "person",
  "package",
]);

export function isSafeCameraId(cameraId: string): boolean {
  const trimmed = cameraId.trim();
  return (
    trimmed.length > 0 &&
    trimmed.length <= 256 &&
    trimmed === cameraId &&
    !trimmed.includes("://") &&
    !/[\s\r\n\t\x00-\x1f]/.test(trimmed)
  );
}

export function isSafeSnapshotFilename(name: string): boolean {
  if (!name || name.length > 128) return false;
  if (
    name.includes("/") ||
    name.includes("\\") ||
    name.includes("..") ||
    name.includes("://") ||
    name.includes(":") ||
    name.includes("?") ||
    name.includes("#") ||
    name.includes("@")
  ) {
    return false;
  }
  return /^snapshot-[a-zA-Z0-9._-]+\.jpe?g$/i.test(name);
}

export function sanitizeCameraEventRecord(raw: unknown): CameraEvent | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const id = typeof obj.id === "string" ? obj.id.trim() : "";
  const cameraID = typeof obj.cameraID === "string" ? obj.cameraID : "";
  const kind = typeof obj.kind === "string" ? obj.kind : "";
  const timestamp = typeof obj.timestamp === "string" ? obj.timestamp.trim() : "";
  if (!id || id.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(id)) return null;
  if (!isSafeCameraId(cameraID)) return null;
  if (!ALLOWED_KINDS.has(kind)) return null;
  const parsedMs = Date.parse(timestamp);
  if (!Number.isFinite(parsedMs)) return null;
  const rawSnapshot = obj.snapshotFile;
  const snapshotFile =
    typeof rawSnapshot === "string" && isSafeSnapshotFilename(rawSnapshot) ? rawSnapshot : null;
  return {
    id,
    cameraID,
    kind: kind as CameraEventKind,
    timestamp: new Date(parsedMs).toISOString(),
    snapshotFile,
  };
}

/**
 * Mirrors macOS `HomeStore.stillWallCameras`: cameras that recorded an event lead in list order,
 * followed by quiet cameras in list order, capped at 4 for the 2x2 grid.
 */
export function selectStillWallCameras(
  devices: readonly SmartDevice[],
  hasEvent: (cameraId: string) => boolean,
  limit = CAMERA_STILL_WALL_LIMIT,
): SmartDevice[] {
  const cap = Math.max(0, limit);
  if (cap === 0) return [];
  const cameras = devices.filter((device) => device.kind.kind === "camera");
  const eventful = cameras.filter((camera) => hasEvent(camera.id));
  const quiet = cameras.filter((camera) => !hasEvent(camera.id));
  return [...eventful, ...quiet].slice(0, cap);
}

export function createTauriCameraEventPersistence(): CameraEventPersistence | null {
  if (typeof window === "undefined" || !window.__TAURI_INTERNALS__?.invoke) return null;
  const invoke = () => window.__TAURI_INTERNALS__?.invoke;
  return {
    async load() {
      const fn = invoke();
      if (!fn) return [];
      const result = await fn<unknown[]>("camera_events_load");
      return Array.isArray(result) ? result : [];
    },
    async record(input) {
      const fn = invoke();
      if (!fn) return null;
      return fn<unknown>("camera_events_record", {
        cameraId: input.cameraID,
        kind: input.kind,
        timestampMs: input.timestampMs,
        snapshotBase64: input.snapshotBase64 ?? null,
      });
    },
    async attachSnapshot(eventId, snapshotBase64) {
      const fn = invoke();
      if (!fn) return null;
      return fn<unknown>("camera_events_attach_snapshot", {
        eventId,
        snapshotBase64,
      });
    },
    async readSnapshot(snapshotFile) {
      const fn = invoke();
      if (!fn) return null;
      return fn<string | null>("camera_events_read_snapshot", { snapshotFile });
    },
    async clear() {
      const fn = invoke();
      if (!fn) return;
      await fn<void>("camera_events_clear");
    },
  };
}

export interface CameraEventStoreOptions {
  readonly retentionMs?: number;
  readonly limit?: number;
  readonly now?: () => number;
  readonly persistence?: CameraEventPersistence | null;
}

export class CameraEventStore {
  private readonly retentionMs: number;
  private readonly limit: number;
  private readonly now: () => number;
  private readonly persistence: CameraEventPersistence | null;
  private events: CameraEvent[] = [];
  private readonly snapshotCache = new Map<string, string>();
  private readonly inflightHydrations = new Set<string>();
  private _revision = 0;
  private idCounter = 0;

  constructor(options: CameraEventStoreOptions = {}) {
    this.retentionMs = Math.max(0, options.retentionMs ?? CAMERA_EVENT_RETENTION_MS);
    this.limit = Math.max(1, options.limit ?? CAMERA_EVENT_LIMIT);
    this.now = options.now ?? (() => Date.now());
    this.persistence = options.persistence ?? null;
  }

  public get revision(): number {
    return this._revision;
  }

  public allEvents(): readonly CameraEvent[] {
    return this.events;
  }

  public latestEvent(cameraID: string): CameraEvent | null {
    return this.events.find((event) => event.cameraID === cameraID) ?? null;
  }

  public snapshotBase64(event: CameraEvent): string | null {
    if (!event.snapshotFile || !isSafeSnapshotFilename(event.snapshotFile)) return null;
    return this.snapshotCache.get(event.snapshotFile) ?? null;
  }

  public snapshotDataUrl(event: CameraEvent): string | null {
    const b64 = this.snapshotBase64(event);
    return b64 ? `data:image/jpeg;base64,${b64}` : null;
  }

  public async load(): Promise<readonly CameraEvent[]> {
    if (!this.persistence) {
      this.prune(this.now());
      return this.events;
    }
    try {
      const raw = await this.persistence.load();
      const parsed = raw.map(sanitizeCameraEventRecord).filter((e): e is CameraEvent => e !== null);
      this.events = parsed;
      this.prune(this.now());
      this._revision += 1;
    } catch {
      // Keep current in-memory state if disk load fails.
    }
    return this.events;
  }

  public record(input: {
    readonly cameraID: string;
    readonly kind: CameraEventKind;
    readonly timestampMs?: number;
    readonly snapshotBase64?: string | null;
  }): CameraEvent | null {
    if (!isSafeCameraId(input.cameraID) || !ALLOWED_KINDS.has(input.kind)) return null;
    const tsMs = input.timestampMs ?? this.now();
    if (!Number.isFinite(tsMs)) return null;
    const localId = this.nextId();
    const cleanB64 = input.snapshotBase64?.trim() ? input.snapshotBase64.trim() : null;
    const snapshotFile = cleanB64 ? `snapshot-${localId}.jpeg` : null;
    const event: CameraEvent = {
      id: localId,
      cameraID: input.cameraID,
      kind: input.kind,
      timestamp: new Date(tsMs).toISOString(),
      snapshotFile,
    };
    if (snapshotFile && cleanB64) {
      this.putSnapshotCache(snapshotFile, cleanB64);
    }
    this.events.unshift(event);
    this.prune(this.now());
    this._revision += 1;

    if (this.persistence) {
      void this.persistence
        .record({
          cameraID: input.cameraID,
          kind: input.kind,
          timestampMs: tsMs,
          snapshotBase64: cleanB64,
        })
        .then((persistedRaw) => {
          const persisted = sanitizeCameraEventRecord(persistedRaw);
          if (!persisted) return;
          const idx = this.events.findIndex((e) => e.id === localId);
          if (idx >= 0) {
            this.events[idx] = persisted;
            if (persisted.snapshotFile && cleanB64) {
              this.putSnapshotCache(persisted.snapshotFile, cleanB64);
            }
            this._revision += 1;
          }
        })
        .catch(() => {});
    }
    return event;
  }

  public attachSnapshot(eventId: string, snapshotBase64: string): CameraEvent | null {
    const cleanB64 = snapshotBase64.trim();
    if (!cleanB64) return null;
    const idx = this.events.findIndex((e) => e.id === eventId && e.snapshotFile === null);
    if (idx < 0) return null;
    const target = this.events[idx]!;
    const snapshotFile = `snapshot-${target.id}.jpeg`;
    const updated: CameraEvent = { ...target, snapshotFile };
    this.events[idx] = updated;
    this.putSnapshotCache(snapshotFile, cleanB64);
    this._revision += 1;

    if (this.persistence) {
      void this.persistence
        .attachSnapshot(target.id, cleanB64)
        .then((persistedRaw) => {
          const persisted = sanitizeCameraEventRecord(persistedRaw);
          if (persisted?.snapshotFile) {
            const cur = this.events.findIndex((e) => e.id === target.id);
            if (cur >= 0) this.events[cur] = persisted;
            this.putSnapshotCache(persisted.snapshotFile, cleanB64);
          }
        })
        .catch(() => {});
    }
    return updated;
  }

  public async hydrateSnapshot(event: CameraEvent): Promise<boolean> {
    const file = event.snapshotFile;
    if (!file || !isSafeSnapshotFilename(file)) return false;
    if (this.snapshotCache.has(file) || this.inflightHydrations.has(file) || !this.persistence) {
      return false;
    }
    this.inflightHydrations.add(file);
    try {
      const b64 = await this.persistence.readSnapshot(file);
      if (b64 && b64.trim()) {
        this.putSnapshotCache(file, b64.trim());
        this._revision += 1;
        return true;
      }
      return false;
    } catch {
      return false;
    } finally {
      this.inflightHydrations.delete(file);
    }
  }

  public clear(): void {
    this.events = [];
    this.snapshotCache.clear();
    this.inflightHydrations.clear();
    this._revision += 1;
    if (this.persistence) {
      void this.persistence.clear().catch(() => {});
    }
  }

  private nextId(): string {
    this.idCounter += 1;
    const randomUuid =
      typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
        ? crypto.randomUUID()
        : `ev-${this.now()}-${this.idCounter}`;
    return randomUuid;
  }

  private putSnapshotCache(file: string, base64: string): void {
    if (this.snapshotCache.has(file)) {
      this.snapshotCache.delete(file);
    }
    this.snapshotCache.set(file, base64);
    while (this.snapshotCache.size > MAX_SNAPSHOT_CACHE_ENTRIES) {
      const oldest = this.snapshotCache.keys().next().value;
      if (oldest === undefined) break;
      this.snapshotCache.delete(oldest);
    }
  }

  private prune(nowMs: number): void {
    const cutoff = nowMs - this.retentionMs;
    const kept: CameraEvent[] = [];
    const removedFiles: string[] = [];
    for (const event of this.events) {
      const ts = Date.parse(event.timestamp);
      if (Number.isFinite(ts) && ts >= cutoff && kept.length < this.limit) {
        kept.push(event);
      } else if (event.snapshotFile) {
        removedFiles.push(event.snapshotFile);
      }
    }
    this.events = kept;
    for (const file of removedFiles) {
      this.snapshotCache.delete(file);
    }
  }
}

export interface StillWallThrottlerOptions {
  readonly perCameraCooldownMs?: number;
  readonly globalGapMs?: number;
  readonly now?: () => number;
  readonly isLiveActive?: () => boolean;
}

/**
 * Serializes still-frame captures so the still wall never opens concurrent live streams for
 * every camera at once and respects the 1-minute per-camera P2P session cooldown.
 */
export class StillWallCaptureThrottler {
  private readonly perCameraCooldownMs: number;
  private readonly globalGapMs: number;
  private readonly now: () => number;
  private readonly isLiveActive: () => boolean;
  private readonly lastCaptureAtMs = new Map<string, number>();
  private lastGlobalCaptureAtMs = -Infinity;
  private inFlight = false;
  private generation = 0;

  constructor(options: StillWallThrottlerOptions = {}) {
    this.perCameraCooldownMs = Math.max(0, options.perCameraCooldownMs ?? CAMERA_STILL_REFRESH_COOLDOWN_MS);
    this.globalGapMs = Math.max(0, options.globalGapMs ?? CAMERA_STILL_GLOBAL_GAP_MS);
    this.now = options.now ?? (() => Date.now());
    this.isLiveActive = options.isLiveActive ?? (() => false);
  }

  public canCapture(cameraId: string): boolean {
    if (this.inFlight || this.isLiveActive()) return false;
    const now = this.now();
    if (now - this.lastGlobalCaptureAtMs < this.globalGapMs) return false;
    const last = this.lastCaptureAtMs.get(cameraId);
    if (last !== undefined && now - last < this.perCameraCooldownMs) return false;
    return true;
  }

  public async captureOnce(
    cameraId: string,
    fetchStill: () => Promise<string | null>,
  ): Promise<string | null> {
    if (!this.canCapture(cameraId)) return null;
    const gen = this.generation;
    this.inFlight = true;
    const startedAt = this.now();
    this.lastGlobalCaptureAtMs = startedAt;
    this.lastCaptureAtMs.set(cameraId, startedAt);
    try {
      const result = await fetchStill();
      if (gen !== this.generation) return null;
      return result;
    } finally {
      if (gen === this.generation) {
        this.inFlight = false;
      }
    }
  }

  public reset(): void {
    this.generation += 1;
    this.inFlight = false;
    this.lastCaptureAtMs.clear();
    this.lastGlobalCaptureAtMs = -Infinity;
  }
}
