import { executeMiScene, miSceneAccount } from "./miCloud/scenes.js";
import { t } from "./i18n.js";
import { HaBlockedRequestError, getHaScopeLifecyclePhase, haConnectionScope } from "./haTransportGate.js";
import type { HomeAssistantClient } from "./homeAssistant.js";
import { MiotCommandMapper, miotShortName, propKeyString } from "./miCloudClient.js";
import type { MiCloudClient, MiotSpecResolver } from "./miCloudClient.js";
import {
  isChannelPowerProperty,
  isMultiKeySwitchSpec,
  type MiCloudChannelWriteBatcher,
} from "./miCloud/channelWriteBatcher.js";
import { readMiotPower, type DeviceCommand, type SmartDevice, type SynthesizedHome } from "./models.js";

export interface ExecuteOptions {
  /** Read the power property back after a power write, on a backend that can read one property. */
  readonly readBackPower?: boolean;
  readonly userInitiated?: boolean;
  /**
   * Called once everything the send needs is resolved, right before the first request. Throwing
   * here cancels the send, so the caller can refuse a command whose source changed while the
   * provider was resolving it.
   */
  readonly beforeSend?: () => void;
  /**
   * Awaited once the provider has finished its own waits (spec lookup, connection ready), before
   * any LAN or cloud request. Throwing cancels the send with nothing on the wire.
   */
  readonly beforeSendAsync?: () => Promise<void>;
  readonly beforeFallback?: () => void | Promise<void>;
  /**
   * Re-checked right before a coalesced multi-channel batch is sent (after the 100 ms window) and
   * again before cloud fallback. Returning false cancels that channel's write without touching the wire.
   */
  readonly stillAllowed?: () => boolean | Promise<boolean>;
}

/** The dispatch surface shared by all built-in sources (ADR-0020). */
export interface HomeCommandProvider {
  /**
   * Sends one command. Resolves to the power state read back after the write when
   * `readBackPower` was asked for and the backend could read it, otherwise to null.
   */
  execute(command: DeviceCommand, options?: ExecuteOptions): Promise<boolean | null>;
}

export type HomeProviderEvent = { readonly kind: "snapshotUpdated"; readonly home: SynthesizedHome };

export interface HomeProvider extends HomeCommandProvider {
  snapshot(): Promise<SynthesizedHome>;
  /** Observes successful snapshot reads through this provider. Returns an unsubscribe function. */
  subscribe(listener: (event: HomeProviderEvent) => void): () => void;
}

/** Capabilities of the built-in Windows backends, including operations outside the command wrapper. */
export type HomeProviderCapability = "readSnapshot" | "pushEvents" | "control" | "scenes" | "cameras";

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
export class DemoHomeProvider implements HomeCommandProvider {
  async execute(): Promise<null> {
    return null;
  }
}

export class HomeAssistantProvider implements HomeProvider {
  static readonly capabilities: ReadonlySet<HomeProviderCapability> = new Set([
    "readSnapshot", "control", "scenes", "cameras",
  ]);
  private readonly events = new EventTarget();

  /** `ready` settles once the endpoint the client talks to has been accepted by the native side. */
  constructor(
    private readonly client: Pick<HomeAssistantClient, "execute" | "snapshot"> & { readonly baseURL?: string },
    private readonly ready: Promise<unknown> = Promise.resolve(),
  ) {}

  async snapshot(): Promise<SynthesizedHome> {
    await this.ready;
    const home = await this.client.snapshot();
    const event: HomeProviderEvent = { kind: "snapshotUpdated", home };
    this.events.dispatchEvent(new CustomEvent(event.kind, { detail: event }));
    return home;
  }

  subscribe(listener: (event: HomeProviderEvent) => void): () => void {
    const receive = (event: Event): void => listener((event as CustomEvent<HomeProviderEvent>).detail);
    this.events.addEventListener("snapshotUpdated", receive);
    return () => this.events.removeEventListener("snapshotUpdated", receive);
  }

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<null> {
    const scope = this.client.baseURL ? haConnectionScope(this.client.baseURL) : null;
    if (scope && getHaScopeLifecyclePhase(scope) !== "enabled") {
      throw new HaBlockedRequestError(scope);
    }
    await this.ready;
    if (options.beforeSendAsync) await options.beforeSendAsync();
    if (scope && getHaScopeLifecyclePhase(scope) !== "enabled") {
      throw new HaBlockedRequestError(scope);
    }
    options.beforeSend?.();
    await this.client.execute(command, options.userInitiated);
    return null;
  }
}

export interface MiCloudProviderDependencies {
  readonly client: Pick<MiCloudClient, "setProps" | "getProps" | "action"> &
    Partial<Pick<MiCloudClient, "runManualScene" | "setPropVerdicts">>;
  readonly sceneForEntity?: (entityId: string) => import("./models.js").HomeScene | undefined;
  readonly specResolver: Pick<MiotSpecResolver, "resolve">;
  /** The card whose controls own this entity id, or undefined when no card does. */
  readonly deviceForEntity: (entityId: string) => SmartDevice | undefined;
  readonly channelBatcher?: MiCloudChannelWriteBatcher;
  readonly accountKey?: string;
}

export class MiCloudProvider implements HomeCommandProvider {
  static readonly capabilities: ReadonlySet<HomeProviderCapability> = new Set([
    "readSnapshot", "control", "scenes", "cameras",
  ]);

  constructor(private readonly dependencies: MiCloudProviderDependencies) {}

  async execute(command: DeviceCommand, options: ExecuteOptions = {}): Promise<boolean | null> {
    const { client, specResolver, deviceForEntity, channelBatcher, accountKey = "" } = this.dependencies;
    if (command.kind === "activateScene" && miSceneAccount(command.entityId)) {
      if (!client.runManualScene) throw new Error("Xiaomi scenes unavailable");
      if (options.beforeSendAsync) await options.beforeSendAsync();
      return executeMiScene(
        { runManualScene: client.runManualScene.bind(client) },
        this.dependencies.sceneForEntity?.(command.entityId),
        options.beforeSend,
        options.userInitiated,
      );
    }
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
    if (options.beforeSendAsync) await options.beforeSendAsync();
    const beforeFallback = options.beforeFallback ?? options.beforeSend;
    const sendSingle = async (): Promise<boolean | null> => {
      options.beforeSend?.();
      if (mapped.kind === "action") {
        await client.action(mapped.call, beforeFallback, options.userInitiated, options.beforeSend);
        return null;
      }
      await client.setProps(mapped.writes, beforeFallback, options.userInitiated, options.beforeSend);
      if (!options.readBackPower) return null;
      const power = mapped.writes.find((write) => {
        if (typeof write.value === "boolean") return true;
        if (write.value !== 0 && write.value !== 1) return false;
        const service = spec.services.find((s) => s.iid === write.siid);
        const prop = service?.properties.find((p) => p.iid === write.piid);
        const shortName = prop ? miotShortName(prop.type) : "";
        return shortName === "on" || shortName === "heating";
      });
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
    };
    if (
      channelBatcher &&
      !options.readBackPower &&
      command.kind === "setSwitch" &&
      mapped.kind === "setProps" &&
      mapped.writes.length === 1 &&
      isChannelPowerProperty(mapped.writes[0]!, spec) &&
      isMultiKeySwitchSpec(spec)
    ) {
      return channelBatcher.enqueue({
        accountKey,
        property: mapped.writes[0]!,
        spec,
        client,
        userInitiated: options.userInitiated,
        beforeSend: options.beforeSend,
        stillAllowed: options.stillAllowed,
        executeSingle: sendSingle,
      });
    }
    return sendSingle();
  }
}
