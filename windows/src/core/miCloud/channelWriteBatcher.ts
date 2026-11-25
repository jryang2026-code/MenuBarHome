import { MiCloudError } from "./session.js";
import type { MiCloudClient, MiotPropWrite } from "./client.js";
import { isMainsBreaker, miotShortName, type MiotDeviceSpec } from "./spec.js";

export const CHANNEL_WRITE_BATCH_WINDOW_MS = 100;

export function isChannelPowerProperty(write: MiotPropWrite, spec: MiotDeviceSpec): boolean {
  const service = spec.services.find((s) => s.iid === write.siid);
  if (!service) return false;
  const serviceShort = miotShortName(service.type);
  if (serviceShort !== "switch" && serviceShort !== "outlet") return false;
  return service.properties.some(
    (p) => p.iid === write.piid && miotShortName(p.type) === "on" && p.access.includes("write"),
  );
}

export function isMultiKeySwitchSpec(spec: MiotDeviceSpec): boolean {
  if (isMainsBreaker(spec)) return false;
  let count = 0;
  for (const s of spec.services) {
    const short = miotShortName(s.type);
    if (short === "switch" || short === "outlet") count += 1;
  }
  return count > 1;
}

export interface ChannelWriteClient {
  setProps: MiCloudClient["setProps"];
  setPropVerdicts?: MiCloudClient["setPropVerdicts"];
}

export interface EnqueueChannelWriteItem {
  readonly accountKey: string;
  readonly property: MiotPropWrite;
  readonly spec: MiotDeviceSpec;
  readonly client: ChannelWriteClient;
  readonly userInitiated?: boolean;
  readonly beforeSend?: () => void;
  readonly stillAllowed?: () => boolean | Promise<boolean>;
  readonly executeSingle: () => Promise<boolean | null>;
}

interface PendingChannelWrite extends EnqueueChannelWriteItem {
  readonly id: number;
  readonly resolve: (value: boolean | null) => void;
  readonly reject: (reason: unknown) => void;
}

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    const timer = globalThis.setTimeout(resolve, ms);
    (timer as { unref?: () => void } | null)?.unref?.();
  });

const aborted = (msg = "Channel write cancelled"): DOMException => new DOMException(msg, "AbortError");

/** Coalesces concurrent power writes to sibling channels of one multi-key MIoT device within 100 ms (#506). */
export class MiCloudChannelWriteBatcher {
  private readonly pending = new Map<string, PendingChannelWrite[]>();
  private readonly draining = new Set<string>();
  private readonly sleep: (ms: number) => Promise<void>;
  private nextId = 1;
  private shutDown = false;

  constructor(options?: { readonly sleep?: (ms: number) => Promise<void> }) {
    this.sleep = options?.sleep ?? defaultSleep;
  }

  pendingCount(did?: string, accountKey = ""): number {
    if (did === undefined) {
      let total = 0;
      for (const list of this.pending.values()) total += list.length;
      return total;
    }
    const direct = this.pending.get(`${accountKey}:${did}`);
    if (direct) return direct.length;
    if (accountKey !== "") return 0;
    let total = 0;
    for (const [key, list] of this.pending) if (key.endsWith(`:${did}`)) total += list.length;
    return total;
  }

  cancelAll(): void {
    for (const list of this.pending.values()) for (const entry of list) entry.reject(aborted());
    this.pending.clear();
  }

  shutdown(): void {
    this.shutDown = true;
    this.cancelAll();
  }

  enqueue(item: EnqueueChannelWriteItem): Promise<boolean | null> {
    if (this.shutDown) return Promise.reject(aborted("Channel write batcher shut down"));
    const batchKey = `${item.accountKey}:${item.property.did}`;
    const id = this.nextId++;
    return new Promise<boolean | null>((resolve, reject) => {
      const list = this.pending.get(batchKey) ?? [];
      const earlierIdx = list.findIndex(
        (e) => e.property.siid === item.property.siid && e.property.piid === item.property.piid,
      );
      if (earlierIdx >= 0) list.splice(earlierIdx, 1)[0]?.reject(aborted("Superseded by newer channel write"));
      list.push({ ...item, id, resolve, reject });
      this.pending.set(batchKey, list);
      if (!this.draining.has(batchKey)) {
        this.draining.add(batchKey);
        void this.drain(batchKey);
      }
    });
  }

  private async drain(batchKey: string): Promise<void> {
    try {
      while (!this.shutDown && (this.pending.get(batchKey)?.length ?? 0) > 0) {
        await this.sleep(CHANNEL_WRITE_BATCH_WINDOW_MS);
        if (this.shutDown) break;
        const queued = this.pending.get(batchKey) ?? [];
        const first = queued[0];
        if (!first) continue;
        const userInitiated = first.userInitiated !== false;
        // Automation writes must not borrow a manual batch's reserved capacity.
        const window = queued.filter((entry) => (entry.userInitiated !== false) === userInitiated);
        const windowIds = new Set(window.map((e) => e.id));
        const rejectedIds = new Set<number>();
        for (const entry of window) {
          if (entry.stillAllowed) {
            try {
              if ((await entry.stillAllowed()) === false) rejectedIds.add(entry.id);
            } catch {
              rejectedIds.add(entry.id);
            }
          }
        }
        const batch: PendingChannelWrite[] = [];
        const remaining: PendingChannelWrite[] = [];
        for (const entry of this.pending.get(batchKey) ?? []) {
          if (!windowIds.has(entry.id)) remaining.push(entry);
          else if (rejectedIds.has(entry.id)) entry.reject(aborted("Control blocked on pre-send re-check"));
          else batch.push(entry);
        }
        if (remaining.length > 0) this.pending.set(batchKey, remaining);
        else this.pending.delete(batchKey);
        if (batch.length === 0) continue;
        if (batch.length === 1) {
          const only = batch[0]!;
          try { only.resolve(await only.executeSingle()); } catch (err) { only.reject(err); }
          continue;
        }
        await this.sendBatch(batch, userInitiated);
      }
    } finally {
      this.draining.delete(batchKey);
      if (!this.shutDown && (this.pending.get(batchKey)?.length ?? 0) > 0) {
        this.draining.add(batchKey);
        void this.drain(batchKey);
      }
    }
  }

  private async sendBatch(batch: readonly PendingChannelWrite[], userInitiated: boolean): Promise<void> {
    const first = batch[0]!;
    const writes = batch.map((e) => e.property);
    if (isMainsBreaker(first.spec) || !writes.every((w) => isChannelPowerProperty(w, first.spec))) {
      const error = new Error(`Unsupported channel batch for ${first.property.did}`);
      for (const entry of batch) entry.reject(error);
      return;
    }
    const beforeSend = (): void => {
      if (this.shutDown) throw aborted("Channel write batcher shut down");
      for (const entry of batch) entry.beforeSend?.();
    };
    const beforeFallback = async (): Promise<void> => {
      if (this.shutDown) throw aborted("Channel write batcher shut down");
      for (const entry of batch) {
        if (entry.stillAllowed && (await entry.stillAllowed()) === false) {
          throw aborted("Control blocked before cloud fallback");
        }
      }
    };
    try {
      beforeSend();
      const verdicts = typeof first.client.setPropVerdicts === "function"
        ? await first.client.setPropVerdicts(writes, beforeFallback, userInitiated, beforeSend)
        : (await first.client.setProps(writes, beforeFallback, userInitiated, beforeSend), writes.map(() => null));
      if (verdicts.length !== batch.length) throw new MiCloudError("badResponse", "Incomplete channel write verdicts");
      batch.forEach((entry, i) => (verdicts[i] ? entry.reject(verdicts[i]) : entry.resolve(null)));
    } catch (error) {
      for (const entry of batch) entry.reject(error);
    }
  }
}
