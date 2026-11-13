import { t } from "./i18n.js";
import type { HomeAssistantClient } from "./homeAssistant.js";
import { MiotCommandMapper, propKeyString } from "./miCloudClient.js";
import type { MiCloudClient, MiotSpecResolver } from "./miCloudClient.js";
import { readMiotPower, type DeviceCommand, type SmartDevice } from "./models.js";

export interface ExecuteOptions {
  /** Read the power property back after a power write, on a backend that can read one property. */
  readonly readBackPower?: boolean;
  /**
   * Called once everything the send needs is resolved, right before the first request. Throwing
   * here cancels the send, so the caller can refuse a command whose source changed while the
   * provider was resolving it.
   */
  readonly beforeSend?: () => void;
}

/**
 * One connection backend (ADR-0020). The panel sends a command through this without knowing which
 * backend is behind it. Mirrors `HomeProvider` in `Sources/MijiaCore/HomeProvider.swift`; methods
 * are added as their callers move behind it.
 */
export interface HomeProvider {
  /**
   * Sends one command. Resolves to the power state read back after the write when
   * `readBackPower` was asked for and the backend could read it, otherwise to null.
   */
  execute(command: DeviceCommand, options?: ExecuteOptions): Promise<boolean | null>;
}

/**
 * The write went out but its read-back gave no usable power state, so the row on screen is no
 * longer a trusted reading. `reason` is the error to show.
 */
export class PowerReadBackError extends Error {
  constructor(readonly reason: unknown) {
    super(reason instanceof Error ? reason.message : String(reason));
    this.name = "PowerReadBackError";
  }
}

/** The built-in virtual home: nothing is sent. */
export class DemoHomeProvider implements HomeProvider {
  async execute(): Promise<null> {
    return null;
  }
}

export class HomeAssistantProvider implements HomeProvider {
  /** `ready` settles once the endpoint the client talks to has been accepted by the native side. */
  constructor(
    private readonly client: Pick<HomeAssistantClient, "execute">,
    private readonly ready: Promise<unknown> = Promise.resolve(),
  ) {}

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<null> {
    await this.ready;
    options.beforeSend?.();
    await this.client.execute(command);
    return null;
  }
}

export interface MiCloudProviderDependencies {
  readonly client: Pick<MiCloudClient, "setProps" | "getProps" | "action">;
  readonly specResolver: Pick<MiotSpecResolver, "resolve">;
  /** The card whose controls own this entity id, or undefined when no card does. */
  readonly deviceForEntity: (entityId: string) => SmartDevice | undefined;
}

export class MiCloudProvider implements HomeProvider {
  constructor(private readonly dependencies: MiCloudProviderDependencies) {}

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<boolean | null> {
    const { client, specResolver, deviceForEntity } = this.dependencies;
    const device = deviceForEntity(command.entityId);
    if (!device) throw new Error(t("无法找到指令对应的设备"));
    const spec = await specResolver.resolve({
      did: device.id,
      name: device.name,
      model: device.model,
      isOnline: device.isOnline,
      specType: null,
    });
    const mapped = MiotCommandMapper.map(command, spec);
    options.beforeSend?.();
    if (mapped.kind === "action") {
      await client.action(mapped.call);
      return null;
    }
    await client.setProps(mapped.writes);
    if (!options.readBackPower) return null;
    const power = mapped.writes.find((write) => typeof write.value === "boolean");
    if (!power) return null;
    let read: Map<string, unknown>;
    try {
      read = await client.getProps([power]);
    } catch (error) {
      throw new PowerReadBackError(error);
    }
    const isOn = readMiotPower(read.get(propKeyString(power)));
    // The write may have landed; the old row is no longer a trusted reading.
    if (isOn === null) throw new PowerReadBackError(new Error(t("未能读回设备状态")));
    return isOn;
  }
}
