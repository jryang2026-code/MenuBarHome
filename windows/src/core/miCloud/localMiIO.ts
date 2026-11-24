import { t, tr3 } from "../i18n.js";
import type { MiDeviceRecord, MiRoom, MiotPropKey } from "./client.js";
import { MiCloudError, type MiSession } from "./session.js";

type Invoke = NonNullable<Window["__TAURI_INTERNALS__"]>["invoke"];
type Endpoint = { did: string; ip: string; token: string };
type Health = { ip: string; token: string; failures: number; retryAt: number };

// Device records also feed diagnostics and snapshots. Keep credentials outside that data.
const recordTokens = new WeakMap<MiDeviceRecord, string>();
const sessionHealth = new WeakMap<MiSession, Map<string, Health>>();

export function rememberMiIODeviceToken(record: MiDeviceRecord, raw: unknown): void {
  if (typeof raw !== "string") return;
  const token = raw.trim();
  if (/^[\da-f]{32}$/i.test(token)) recordTokens.set(record, token);
}

function isPrivateIPv4(ip: string): boolean {
  const [a, b = 0] = ip.split(".").map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

export class MiIOUnconfirmedWriteError extends Error {
  constructor() {
    super(tr3(
      "局域网设备未确认执行结果",
      "區域網路裝置未確認執行結果",
      "The LAN device did not confirm the command outcome",
    ));
  }
}

export class LocalMiIO {
  readonly #endpoints = new Map<string, Endpoint>();
  readonly #health: Map<string, Health>;

  constructor(session: MiSession, devices: readonly MiDeviceRecord[], rooms: readonly MiRoom[], private readonly invoke: Invoke) {
    this.#health = sessionHealth.get(session) ?? new Map();
    sessionHealth.set(session, this.#health);
    const shared = new Set(rooms.filter((room) => room.isSharedHome).flatMap((room) => room.dids));
    for (const device of devices) {
      if (shared.has(device.did) && device.splitParentDid) shared.add(device.splitParentDid);
      if (device.isShared && device.splitParentDid) shared.add(device.splitParentDid);
    }
    for (const device of devices) {
      const ip = device.localIp;
      const token = recordTokens.get(device);
      if (device.isOnline && !device.isShared && !shared.has(device.did) &&
          !device.splitParentDid && !device.parentDid && !device.did.startsWith("group.") &&
          ip && isPrivateIPv4(ip) && token) {
        this.#endpoints.set(device.did, { did: device.did, ip, token });
      }
    }
  }

  private endpoint(did: string): Endpoint | undefined {
    const endpoint = this.#endpoints.get(did);
    if (!endpoint) return undefined;
    const health = this.#health.get(did);
    if (health && (health.ip !== endpoint.ip || health.token !== endpoint.token)) {
      this.#health.delete(did);
    } else if (health && Date.now() < health.retryAt) {
      return undefined;
    }
    return endpoint;
  }

  private recordFailure(endpoint: Endpoint): void {
    const previous = this.#health.get(endpoint.did);
    const failures = previous?.ip === endpoint.ip && previous.token === endpoint.token
      ? previous.failures + 1 : 1;
    this.#health.set(endpoint.did, {
      ip: endpoint.ip,
      token: endpoint.token,
      failures,
      retryAt: failures >= 3 ? Date.now() + 30_000 : 0,
    });
  }

  async read(did: string, keys: readonly MiotPropKey[]): Promise<readonly (MiotPropKey & { value: unknown })[]> {
    const endpoint = this.endpoint(did);
    if (!endpoint) return [];
    try {
      const reply = await this.invoke<{ values: Array<MiotPropKey & { value: unknown }> }>(
        "miio_get_props", { endpoint, keys },
      );
      if (!Array.isArray(reply.values)) return [];
      this.#health.delete(did);
      return reply.values;
    } catch {
      this.recordFailure(endpoint);
      return [];
    }
  }

  write(
    did: string,
    command: "miio_set_props" | "miio_call_action",
    args: Record<string, unknown>,
  ): Promise<{ sent: false } | { sent: true; result: unknown }> | undefined {
    const endpoint = this.endpoint(did);
    if (endpoint) return this.sendWrite(endpoint, command, args);
  }

  private async sendWrite(
    endpoint: Endpoint,
    command: "miio_set_props" | "miio_call_action",
    args: Record<string, unknown>,
  ): Promise<{ sent: false } | { sent: true; result: unknown }> {
    try {
      const reply = await this.invoke<{ result?: unknown }>(command, { endpoint, ...args });
      this.#health.delete(endpoint.did);
      return { sent: true, result: reply.result };
    } catch (error) {
      // Rust is the only layer that knows whether the write reached the UDP send boundary.
      const code = error && typeof error === "object" && "code" in error ? error.code : null;
      if (code === "device_error") {
        const deviceCode = (error as { deviceCode?: unknown }).deviceCode;
        throw new MiCloudError("api", t("设备未响应或离线"),
          typeof deviceCode === "number" ? deviceCode : undefined);
      }
      if (code === "shut_down") throw new DOMException("Local device transport shut down", "AbortError");
      this.recordFailure(endpoint);
      if (code === "write_not_sent") return { sent: false };
      throw new MiIOUnconfirmedWriteError();
    }
  }
}
