import { tr3 } from "../core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../core/models.js";
import {
  defaultTVBridgeConfig,
  mapTVBridgeCommand,
  normalizeTVBridgeDriver,
  normalizeTVBridgeMac,
  projectTVBridgeDevice,
  tvBridgeDescriptorMacs,
  TVBridgeLifecycle,
  type TVBridgeCommand,
  type TVBridgeConfig,
  type TVBridgeDeviceConfig,
  type TVBridgeDeviceDescriptor,
  type TVBridgeDriver,
  type TVBridgeDriverTier,
  type TVBridgeFrame,
  type TVBridgePollingContext,
} from "../core/tvBridgePlugin.js";
import { getCapabilityGeneration } from "../core/miAccountControl.js";
import { secureStoreDelete, secureStoreGet, secureStoreSet, tvBridgeCredentialName } from "../core/secureStore.js";

/**
 * Optional multi-brand TV bridge (ADR-0026), the Windows twin of macOS `TVBridgeStore`. Off by
 * default: while off it makes zero `tv_bridge_*` IPC calls, adds no panel rows and runs no timer.
 * Pairing secrets go to the OS credential store (`tv-bridge:<nativeId>`); the saved config holds
 * only the slot name. Rows join `host.devices` behind every built-in row and never replace one.
 */
export const TV_BRIDGE_STORAGE_KEY = "tv_bridge_config_v1";
export const TV_BRIDGE_DEVICE_PREFIX = "adapter:com.menubarhome.tv-bridge:";

export type TVBridgeInvoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
export interface TVBridgeStorage { getItem(key: string): string | null; setItem(key: string, value: string): void }
export interface TVBridgeSecrets {
  get(slot: string): Promise<string | null>;
  set(slot: string, value: string): Promise<void>;
  delete(slot: string): Promise<void>;
}
export type TVBridgeStatus = "disabled" | "missingBinary" | "idle" | "running" | "failed";

export interface TVBridgeDriverOption {
  readonly id: TVBridgeDriver;
  readonly tier: TVBridgeDriverTier;
  readonly label: [string, string, string];
  readonly port: number;
  readonly secret?: [string, string, string];
}

export const TV_BRIDGE_DRIVERS: readonly TVBridgeDriverOption[] = [
  { id: "lg_webos_ssap", tier: "primary", label: ["LG webOS", "LG webOS", "LG webOS"], port: 3001, secret: ["配对密钥（Client Key）", "配對金鑰（Client Key）", "Client key"] },
  { id: "xiaomi_mitv_6095", tier: "primary", label: ["小米 / Redmi 电视", "小米 / Redmi 電視", "Xiaomi / Redmi TV"], port: 6095 },
  { id: "hisense_vidaa_mqtt", tier: "primary", label: ["海信电视（海外 VIDAA）", "海信電視（海外 VIDAA）", "Hisense TV (Overseas VIDAA)"], port: 36669, secret: ["配对码（PIN，可选）", "配對碼（PIN，選用）", "Pairing PIN (optional)"] },
  { id: "samsung_tizen_ws", tier: "experimental", label: ["三星 Tizen（实验）", "三星 Tizen（實驗）", "Samsung Tizen (Experimental)"], port: 8002, secret: ["访问令牌（Token）", "存取權杖（Token）", "Access token"] },
  { id: "sony_bravia_psk", tier: "experimental", label: ["索尼 Bravia（实验）", "索尼 Bravia（實驗）", "Sony Bravia (Experimental)"], port: 80, secret: ["预共享密钥（PSK）", "預共享金鑰（PSK）", "Pre-shared key (PSK)"] },
  { id: "tcl_ffalcon_tnscreen", tier: "experimental", label: ["雷鸟 / TCL（实验）", "雷鳥 / TCL（實驗）", "FFalcon / TCL (Experimental)"], port: 6553 },
  { id: "android_adb_lan", tier: "experimental", label: ["通用安卓电视 ADB（实验）", "通用安卓電視 ADB（實驗）", "Generic Android TV ADB (Experimental)"], port: 5555 },
  { id: "dlna_dmr", tier: "experimental", label: ["DLNA（实验）", "DLNA（實驗）", "DLNA (Experimental)"], port: 1900 },
  { id: "kodi_jsonrpc", tier: "experimental", label: ["Kodi（实验）", "Kodi（實驗）", "Kodi (Experimental)"], port: 8080 },
];

export function visibleTVBridgeDrivers(includeExperimental: boolean): readonly TVBridgeDriverOption[] {
  return includeExperimental ? TV_BRIDGE_DRIVERS : TV_BRIDGE_DRIVERS.filter((d) => d.tier === "primary");
}

const EMPTY: readonly SmartDevice[] = Object.freeze([]);

export function isTVBridgeDeviceId(id: string): boolean {
  return id.startsWith(TV_BRIDGE_DEVICE_PREFIX);
}

/** Every drawer/card control targets the row id; mute is addressed as `<id>#mute`. */
export function routableTVBridgeDevice(device: SmartDevice): SmartDevice {
  if (device.kind.kind !== "tv") return device;
  return { ...device, kind: { ...device.kind, mediaEntityId: device.id, remoteEntityId: device.id, muteSwitchEntityId: `${device.id}#mute` } };
}

const normalizedName = (name: string): string => name.toLowerCase().replace(/[\s\p{P}]/gu, "");

export interface TVBridgeDedupeOptions {
  /** Normalized MACs the bridge reported for a row. */
  readonly macsFor?: (row: SmartDevice) => readonly string[];
  /** Hardware identifiers (MACs, dids, unique ids) the host knows for a built-in row; defaults to its id. */
  readonly builtInIdentifiers?: (device: SmartDevice) => readonly string[];
}

/**
 * ADR-0024 §5.3: the built-in row always keeps the card. A bridged row is a duplicate when a built-in
 * row has its id, the same normalized TV name, or the same MAC among its identifiers.
 */
export function nonHijackingTVBridgeRows(
  bridged: readonly SmartDevice[],
  builtIn: readonly SmartDevice[],
  options: TVBridgeDedupeOptions = {},
): SmartDevice[] {
  const native = builtIn.filter((d) => !isTVBridgeDeviceId(d.id));
  const ids = new Set(native.map((d) => d.id));
  const tvNames = new Set(native.filter((d) => d.kind.kind === "tv").map((d) => normalizedName(d.name)));
  const identifiers = options.builtInIdentifiers ?? ((d: SmartDevice) => [d.id]);
  const hexIds = native.flatMap((d) => identifiers(d)).map((raw) => raw.toLowerCase().replace(/[^0-9a-f]/g, ""));
  return bridged.filter((d) => {
    if (ids.has(d.id) || tvNames.has(normalizedName(d.name))) return false;
    const macs = (options.macsFor?.(d) ?? []).map(normalizeTVBridgeMac).filter((m): m is string => m !== null);
    return !macs.some((mac) => hexIds.some((hex) => hex.includes(mac)));
  });
}

export function toTVBridgeCommand(command: DeviceCommand): { deviceId: string; command: TVBridgeCommand } | null {
  const [deviceId = "", control] = command.entityId.split("#", 2);
  if (!isTVBridgeDeviceId(deviceId)) return null;
  const mapped: TVBridgeCommand | null = (() => {
    switch (command.kind) {
      case "setSwitch": return control === "mute" ? { kind: "setMute", isMuted: command.isOn } : control === undefined ? { kind: "power", isOn: command.isOn } : null;
      case "pressButton": return control === "power.on" ? { kind: "power", isOn: true } : control === "power.off" ? { kind: "power", isOn: false } : null;
      case "mediaSetVolume": return { kind: "setVolume", level: command.level };
      case "mediaSelectSource": return { kind: "selectSource", source: command.source };
      case "mediaPlayPause": return { kind: "playPause" };
      case "mediaNextTrack": return { kind: "next" };
      case "mediaPreviousTrack": return { kind: "previous" };
      case "mediaSeek": return { kind: "seek", seconds: command.positionSec };
      case "remoteSendKey": return { kind: "remoteKey", key: command.key };
      default: return null;
    }
  })();
  return mapped ? { deviceId, command: mapped } : null;
}

function defaultStorage(): TVBridgeStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

function defaultInvoke(): TVBridgeInvoke | null {
  const tauri = typeof window === "undefined" ? undefined : window.__TAURI_INTERNALS__;
  return tauri?.invoke ? (cmd, args) => tauri.invoke(cmd, args) : null;
}

/** The OS credential store, with a session-only fallback while the native slot is not available. */
function defaultSecrets(): TVBridgeSecrets {
  const memory = new Map<string, string>();
  return {
    async get(slot) {
      try { return (await secureStoreGet(tvBridgeCredentialName(slot))) ?? memory.get(slot) ?? null; } catch { return memory.get(slot) ?? null; }
    },
    async set(slot, value) {
      try { await secureStoreSet(tvBridgeCredentialName(slot), value); memory.delete(slot); } catch { memory.set(slot, value); }
    },
    async delete(slot) {
      memory.delete(slot);
      try { await secureStoreDelete(tvBridgeCredentialName(slot)); } catch { /* nothing stored natively */ }
    },
  };
}

function loadConfig(storage: TVBridgeStorage | null): TVBridgeConfig {
  try {
    const raw = storage?.getItem(TV_BRIDGE_STORAGE_KEY);
    const parsed = raw ? (JSON.parse(raw) as Partial<TVBridgeConfig>) : null;
    if (!parsed || typeof parsed !== "object") return defaultTVBridgeConfig();
    const devices = Array.isArray(parsed.devices)
      ? parsed.devices.flatMap((entry) => {
          if (!entry || typeof entry !== "object") return [];
          const driver = normalizeTVBridgeDriver((entry as { driver?: unknown }).driver);
          return driver ? [{ ...(entry as TVBridgeDeviceConfig), driver }] : [];
        })
      : [];
    return { ...defaultTVBridgeConfig(), ...parsed, isEnabled: parsed.isEnabled === true, devices };
  } catch {
    return defaultTVBridgeConfig();
  }
}

function friendlyError(error: unknown): string {
  const text = String((error as { message?: unknown })?.message ?? error ?? "");
  if (/not found|unknown command|not allowed|command .* not/i.test(text)) {
    return tr3("当前版本尚未包含电视桥接组件，请更新应用后再试", "目前版本尚未包含電視橋接元件，請更新應用程式後再試", "This build doesn't include the TV bridge yet. Update the app and try again");
  }
  return tr3("无法启动或连接 mbh-tv-bridge.exe，请检查二进制路径与电视网络", "無法啟動或連線 mbh-tv-bridge.exe，請檢查執行檔路徑與電視網路", "Couldn't start or reach mbh-tv-bridge.exe. Check the binary path and the TV's network");
}

export interface TVBridgeControllerDeps {
  readonly invoke?: TVBridgeInvoke | null;
  readonly storage?: TVBridgeStorage | null;
  readonly secrets?: TVBridgeSecrets;
  readonly onChange?: () => void;
  /** Live host capability generation (`>= 1`); defaults to the capability selection store counter. */
  readonly getCapabilityGeneration?: () => number;
  /** Delay before an idle bridge stops after the panel hides; defaults to `idleShutdownSeconds`. */
  readonly idleShutdownMs?: number;
}

export interface TVBridgeDeviceInput { name: string; roomName: string; driver: TVBridgeDriver; host: string; port?: number; macAddress?: string; secret?: string }

export class TVBridgeController {
  private readonly storage: TVBridgeStorage | null;
  private readonly invokeFn: TVBridgeInvoke | null;
  private readonly secrets: TVBridgeSecrets;
  private readonly capabilityGenerationFn: () => number;
  onChange: () => void;
  config: TVBridgeConfig;
  status: TVBridgeStatus;
  error: string | null = null;
  showExperimentalDrivers = false;
  panelDevices: readonly SmartDevice[] = EMPTY;
  private lifecycle: TVBridgeLifecycle | null = null;
  private refreshing: Promise<void> | null = null;
  private readonly pending = new Set<Promise<unknown>>();
  /** Bumped by every dispose and config change; a start or snapshot from an older epoch is dropped. */
  private generation = 0;
  private starting: Promise<TVBridgeLifecycle> | null = null;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly idleShutdownMs: number | undefined;
  private panelVisible = false;
  /**
   * The native side keeps one process slot, so every launch and every stop runs on this chain: a
   * stale start's or an old dispose's `tv_bridge_shutdown` always lands before the next
   * `tv_bridge_start` and can never kill the process that replaced it.
   */
  private nativeOps: Promise<void> = Promise.resolve();
  /** Incremented on each native launch; stale `close` callbacks compare against it on `nativeOps`. */
  private runEpoch = 0;
  private readonly stoppingOnNativeChain = new WeakSet<TVBridgeLifecycle>();
  private hardwareIds = new Map<string, readonly string[]>();

  constructor(deps: TVBridgeControllerDeps = {}) {
    this.storage = deps.storage === undefined ? defaultStorage() : deps.storage;
    this.invokeFn = deps.invoke === undefined ? defaultInvoke() : deps.invoke;
    this.secrets = deps.secrets ?? defaultSecrets();
    this.capabilityGenerationFn = deps.getCapabilityGeneration ?? getCapabilityGeneration;
    this.onChange = deps.onChange ?? (() => undefined);
    this.idleShutdownMs = deps.idleShutdownMs;
    this.config = loadConfig(this.storage);
    this.status = this.idleStatus();
  }

  get enabled(): boolean { return this.config.isEnabled }
  get isRefreshing(): boolean { return this.refreshing !== null }
  /** Normalized MACs for a bridged row, from its snapshot and its configured `macAddress`. */
  macsFor(deviceId: string): readonly string[] { return this.hardwareIds.get(deviceId) ?? [] }

  setEnabled(enabled: boolean): void {
    if (enabled === this.config.isEnabled) return;
    this.apply({ ...this.config, isEnabled: enabled });
  }

  setBinaryPath(path: string): void {
    const binaryPath = path.trim() || undefined;
    if (binaryPath !== this.config.binaryPath) this.apply({ ...this.config, binaryPath });
  }

  setExpectedSHA256(digest: string): void {
    const expectedBinarySHA256 = digest.trim().toLowerCase() || undefined;
    if (expectedBinarySHA256 !== this.config.expectedBinarySHA256) this.apply({ ...this.config, expectedBinarySHA256 });
  }

  setShowExperimentalDrivers(show: boolean): void {
    if (show === this.showExperimentalDrivers) return;
    this.showExperimentalDrivers = show;
    this.onChange();
  }

  async addDevice(input: TVBridgeDeviceInput): Promise<boolean> {
    const name = input.name.trim();
    const host = input.host.trim();
    const driver = normalizeTVBridgeDriver(input.driver);
    if (!name || !host || !driver || (input.port !== undefined && !(Number.isInteger(input.port) && input.port >= 1 && input.port <= 65535))) return false;
    const nativeId = `tv-${crypto.randomUUID().slice(0, 8)}`;
    const needsSecret = TV_BRIDGE_DRIVERS.some((d) => d.id === driver && d.secret);
    const secret = input.secret?.trim();
    let credentialSlot: string | undefined;
    if (needsSecret && secret) {
      credentialSlot = nativeId;
      try { await this.secrets.set(credentialSlot, secret); } catch { return false; }
    }
    const mac = input.macAddress?.trim();
    const device: TVBridgeDeviceConfig = {
      nativeId, driver, host, name, roomName: input.roomName.trim(),
      ...(input.port === undefined ? {} : { port: input.port }),
      ...(mac ? { macAddress: mac } : {}),
      ...(credentialSlot ? { credentialSlot } : {}),
    };
    this.apply({ ...this.config, devices: [...this.config.devices, device] });
    return true;
  }

  async removeDevice(nativeId: string): Promise<void> {
    const removed = this.config.devices.find((d) => d.nativeId === nativeId);
    if (!removed) return;
    if (removed.credentialSlot) { try { await this.secrets.delete(removed.credentialSlot); } catch { /* best effort */ } }
    this.apply({ ...this.config, devices: this.config.devices.filter((d) => d.nativeId !== nativeId) });
  }

  /** Panel shown: refresh. A no-op while off. */
  onPanelShown(): void {
    this.panelVisible = true;
    this.clearIdleTimer();
    if (!this.config.isEnabled) return;
    this.track(this.contextChanged({ panelVisible: true, systemActive: true, lowPower: false }));
    void this.refresh();
  }

  /**
   * Panel hidden: let the bridge sleep, then stop it once the idle window passes. `host.contextChanged`
   * never fires again while the panel stays shut, so the stop is a one-shot timer of its own. A no-op
   * (and no timer) while off or not running.
   */
  onPanelHidden(): void {
    this.panelVisible = false;
    if (!this.config.isEnabled || !this.lifecycle?.isRunning) return;
    this.track(this.contextChanged({ panelVisible: false, systemActive: false, lowPower: false }).then(() => this.scheduleIdleShutdown()));
  }

  refresh(): Promise<void> {
    if (!this.config.isEnabled) return Promise.resolve();
    if (this.refreshing) return this.refreshing;
    if (!this.config.binaryPath) {
      this.status = "missingBinary";
      this.onChange();
      return Promise.resolve();
    }
    if (this.config.devices.length === 0) {
      this.publish(EMPTY);
      return Promise.resolve();
    }
    const token = this.generation;
    const run = (async () => {
      let rows: readonly SmartDevice[] = EMPTY;
      let failure: unknown = null;
      try {
        const result = (await this.request("snapshot", {})) as { devices?: TVBridgeDeviceDescriptor[] } | null;
        const descriptors = result?.devices ?? [];
        rows = descriptors.map((d) => routableTVBridgeDevice(projectTVBridgeDevice(d)));
        if (token === this.generation) this.hardwareIds = this.hardwareIdsFrom(descriptors);
      } catch (error) {
        failure = error;
      }
      if (token !== this.generation || !this.config.isEnabled) return;
      this.refreshing = null;
      this.error = failure === null ? null : friendlyError(failure);
      this.status = failure === null ? "running" : "failed";
      this.publish(rows);
    })();
    this.refreshing = run;
    this.onChange();
    return run;
  }

  onCapabilityGenerationChanged(): void {
    if (!this.config.isEnabled || !this.lifecycle?.isRunning) return;
    this.track(this.contextChanged({ panelVisible: this.panelVisible, systemActive: this.panelVisible, lowPower: false }));
  }

  /** `stillAllowed` runs after the bridge is up and right before the write; `false` sends nothing. */
  async execute(command: DeviceCommand, stillAllowed?: () => Promise<boolean>, capabilityGeneration?: number): Promise<void> {
    if (!this.config.isEnabled) throw new Error("TV bridge is off");
    const routed = toTVBridgeCommand(command);
    if (!routed) throw new Error("Unsupported TV bridge command");
    const capGen = this.normalizeCapabilityGeneration(capabilityGeneration ?? this.capabilityGenerationFn());
    const frame = mapTVBridgeCommand(routed.command, routed.deviceId, capGen);
    await this.request(frame.method ?? "control.execute", frame.params, async () => {
      const allowed = stillAllowed ? await stillAllowed() : true;
      if (!allowed || !this.config.isEnabled) throw new Error("TV bridge write refused");
    });
    this.lifecycle?.touch();
    void this.refresh();
  }

  async dispose(): Promise<void> {
    this.generation += 1;
    this.refreshing = null;
    this.starting = null;
    this.clearIdleTimer();
    const lifecycle = this.lifecycle;
    this.lifecycle = null;
    if (lifecycle) await this.stop(lifecycle);
  }

  async settle(): Promise<void> {
    while (this.refreshing || this.pending.size > 0) await Promise.all([this.refreshing, ...this.pending]);
  }

  private idleStatus(): TVBridgeStatus {
    if (!this.config.isEnabled) return "disabled";
    return this.config.binaryPath ? "idle" : "missingBinary";
  }

  private apply(next: TVBridgeConfig): void {
    this.config = next;
    try {
      this.storage?.setItem(TV_BRIDGE_STORAGE_KEY, JSON.stringify(next));
    } catch {
      // Blocked storage: the change still holds for this session.
    }
    this.track(this.dispose());
    this.error = null;
    this.status = this.idleStatus();
    if (!next.isEnabled) this.panelDevices = EMPTY;
    this.onChange();
    if (next.isEnabled) void this.refresh();
  }

  private publish(rows: readonly SmartDevice[]): void {
    this.panelDevices = rows.length === 0 ? EMPTY : rows;
    if (rows.length === 0) this.hardwareIds = new Map();
    this.onChange();
  }

  private hardwareIdsFrom(descriptors: readonly TVBridgeDeviceDescriptor[]): Map<string, readonly string[]> {
    const ids = new Map<string, readonly string[]>();
    for (const d of descriptors) {
      const configured = normalizeTVBridgeMac(this.config.devices.find((c) => c.nativeId === d.nativeId)?.macAddress);
      const macs = [...new Set([...tvBridgeDescriptorMacs(d), ...(configured ? [configured] : [])])];
      if (macs.length > 0) ids.set(`${TV_BRIDGE_DEVICE_PREFIX}${d.nativeId}`, macs);
    }
    return ids;
  }

  private scheduleIdleShutdown(): void {
    this.clearIdleTimer();
    const lifecycle = this.lifecycle;
    if (!this.config.isEnabled || this.panelVisible || !lifecycle?.isRunning) return;
    const delay = this.idleShutdownMs ?? this.config.idleShutdownSeconds * 1000;
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      if (this.lifecycle !== lifecycle || this.panelVisible) return;
      this.lifecycle = null;
      this.track(this.stop(lifecycle));
      if (this.status === "running") this.status = this.idleStatus();
      this.onChange();
    }, delay);
    (this.idleTimer as { unref?: () => void }).unref?.();
  }

  private clearIdleTimer(): void {
    if (this.idleTimer !== null) clearTimeout(this.idleTimer);
    this.idleTimer = null;
  }

  private track(task: Promise<unknown>): void {
    this.pending.add(task);
    void task.finally(() => this.pending.delete(task));
  }

  private normalizeCapabilityGeneration(value: number): number {
    const n = Math.floor(value);
    return Number.isFinite(n) && n >= 1 ? n : 1;
  }

  private currentCapabilityGeneration(): number {
    return this.normalizeCapabilityGeneration(this.capabilityGenerationFn());
  }

  private contextChanged(context: TVBridgePollingContext): Promise<void> {
    const lifecycle = this.lifecycle;
    return lifecycle?.contextChanged(context, this.currentCapabilityGeneration()).catch(() => {
      if (this.lifecycle === lifecycle) this.lifecycle = null;
    }) ?? Promise.resolve();
  }

  private ensureStarted(): Promise<TVBridgeLifecycle> {
    if (this.lifecycle?.isRunning) return Promise.resolve(this.lifecycle);
    if (this.starting) return this.starting;
    const epoch = this.generation;
    const run = this.native(() => this.start(epoch)).finally(() => {
      if (this.starting === run) this.starting = null;
    });
    this.starting = run;
    return run;
  }

  /**
   * Launches the process and sends `initialize`. If the switch goes off or the config changes while
   * either await is pending, or `initialize` fails, the process is shut down and nothing is kept.
   */
  private native<T>(op: () => Promise<T>): Promise<T> {
    const run = this.nativeOps.then(op);
    this.nativeOps = run.then(() => undefined, () => undefined);
    return run;
  }

  private stop(lifecycle: TVBridgeLifecycle): Promise<void> {
    return this.native(async () => {
      this.stoppingOnNativeChain.add(lifecycle);
      try {
        await lifecycle.shutdown();
      } finally {
        this.stoppingOnNativeChain.delete(lifecycle);
      }
    }).catch(() => undefined);
  }

  /** Runs on the native chain (see `nativeOps`), so it never calls `native` or `stop` itself. */
  private async start(genEpoch: number): Promise<TVBridgeLifecycle> {
    const stale = () => genEpoch !== this.generation || !this.config.isEnabled;
    const invoke = this.invokeFn;
    if (!invoke) throw new Error("command tv_bridge_start not found");
    if (stale()) throw new Error("TV bridge switched off before starting");
    await invoke("tv_bridge_start", { binaryPath: this.config.binaryPath, expectedSha256: this.config.expectedBinarySHA256 ?? null });
    const epoch = ++this.runEpoch;
    const send = async (frame: TVBridgeFrame): Promise<TVBridgeFrame> => {
      if (epoch !== this.runEpoch) throw new Error("TV bridge process replaced");
      const reply = await invoke("tv_bridge_request", { frame });
      const parsed = (typeof reply === "string" ? JSON.parse(reply) : reply) as TVBridgeFrame | null;
      if (!parsed || parsed.id !== frame.id) throw new Error("Invalid TV bridge frame");
      return parsed;
    };
    try {
      if (stale()) throw new Error("TV bridge switched off while starting");
      const devices = await Promise.all(this.config.devices.map(async (d) => {
        const credential = d.credentialSlot ? await this.secrets.get(d.credentialSlot) : null;
        const { credentialSlot: _slot, macAddress, ...rest } = d;
        return { ...rest, ...(macAddress ? { mac: macAddress } : {}), ...(credential ? { credential } : {}) };
      }));
      if (stale()) throw new Error("TV bridge switched off while starting");
      const init = await send({ jsonrpc: "2.0", id: crypto.randomUUID(), method: "initialize", params: { supportedProtocolVersions: ["1.0"], capabilityGeneration: this.currentCapabilityGeneration(), config: { devices } } });
      if (init.error) throw new Error(typeof init.error === "string" ? init.error : init.error.message);
      if (stale()) throw new Error("TV bridge switched off while starting");
    } catch (error) {
      if (epoch === this.runEpoch) await invoke("tv_bridge_shutdown").catch(() => undefined);
      throw error;
    }
    let closed = false;
    let lifecycle!: TVBridgeLifecycle;
    const closeNative = async (): Promise<void> => {
      if (closed || epoch !== this.runEpoch) return;
      closed = true;
      await invoke("tv_bridge_shutdown");
    };
    lifecycle = new TVBridgeLifecycle(
      { request: send, close: () => (this.stoppingOnNativeChain.has(lifecycle) ? closeNative() : this.native(closeNative)) },
      this.config.idleShutdownSeconds,
    );
    lifecycle.markStarted();
    this.lifecycle = lifecycle;
    // The panel may have closed while the bridge was starting; `onPanelHidden` saw nothing running.
    if (!this.panelVisible) {
      this.track(this.contextChanged({ panelVisible: false, systemActive: false, lowPower: false }).then(() => this.scheduleIdleShutdown()));
    }
    return lifecycle;
  }

  private async request(method: string, params: unknown, beforeSend?: () => Promise<void>): Promise<unknown> {
    const lifecycle = await this.ensureStarted();
    await beforeSend?.();
    const invoke = this.invokeFn!;
    const frame: TVBridgeFrame = { jsonrpc: "2.0", id: crypto.randomUUID(), method, params };
    let reply: TVBridgeFrame;
    try {
      const raw = await invoke("tv_bridge_request", { frame });
      reply = (typeof raw === "string" ? JSON.parse(raw) : raw) as TVBridgeFrame;
      if (!reply || reply.id !== frame.id) throw new Error("Invalid TV bridge frame");
    } catch (error) {
      if (this.lifecycle === lifecycle) this.lifecycle = null;
      await this.stop(lifecycle);
      throw error;
    }
    if (reply.error) throw new Error(typeof reply.error === "string" ? reply.error : reply.error.message);
    lifecycle.touch();
    return reply.result;
  }
}

let shared: TVBridgeController | null = null;

export function getTVBridgeController(): TVBridgeController {
  shared ??= new TVBridgeController();
  return shared;
}

export function setTVBridgeControllerForTesting(controller: TVBridgeController | null): void {
  shared = controller;
}

type Escape = (raw: string) => string;

function renderDriverOptions(drivers: readonly TVBridgeDriverOption[], esc: Escape): string {
  return drivers
    .map((d) => `<option value="${d.id}" data-port="${d.port}" data-secret="${d.secret ? esc(tr3(...d.secret)) : ""}">${esc(tr3(...d.label))}</option>`)
    .join("");
}

function syncDriverFormHints(select: HTMLSelectElement): void {
  const option = select.selectedOptions[0];
  const form = select.closest("form");
  const port = form?.querySelector<HTMLInputElement>("[data-tvbridge-port]");
  const secret = form?.querySelector<HTMLInputElement>("[data-tvbridge-secret]");
  if (port) port.placeholder = tr3("端口，默认 {p}", "連接埠，預設 {p}", "Port, default {p}").replace("{p}", option?.dataset.port ?? "");
  if (secret) {
    secret.hidden = !option?.dataset.secret;
    secret.placeholder = option?.dataset.secret ?? "";
    if (secret.hidden) secret.value = "";
  }
}

/** Settings → 常规 card, below the DDC/CI card. */
export function renderTVBridgeSettingsSection(ctrl: TVBridgeController, esc: Escape): string {
  const title = tr3("多品牌电视桥接插件（可选）", "多品牌電視橋接外掛（選用）", "Multi-brand TV Bridge (Optional)");
  const hint = tr3(
    "首发支持 LG webOS、小米 / Redmi 与海信（海外 VIDAA）；其他品牌可展开实验性协议（未真机验证）。插件在独立进程中运行，未开启时零后台开销；已由 Home Assistant 或米家接入的同一台电视始终由内置来源控制。",
    "首發支援 LG webOS、小米 / Redmi 與海信（海外 VIDAA）；其他品牌可展開實驗性協議（未實機驗證）。外掛在獨立行程中執行，未開啟時零背景開銷；已由 Home Assistant 或米家接入的同一台電視始終由內建來源控制。",
    "Primary support for LG webOS, Xiaomi / Redmi, and Hisense (overseas VIDAA); other protocols are behind the experimental toggle. The plugin runs in its own process and nothing runs while this is off; a TV already connected through Home Assistant or Xiaomi Home stays on the built-in source.",
  );
  let body = "";
  if (ctrl.enabled) {
    const status: Record<TVBridgeStatus, string> = {
      disabled: tr3("未启用", "未啟用", "Off"),
      missingBinary: tr3("未配置 mbh-tv-bridge.exe 路径", "未設定 mbh-tv-bridge.exe 路徑", "mbh-tv-bridge.exe path not set"),
      idle: tr3("待命：打开面板时连接电视", "待命：開啟面板時連線電視", "Idle: connects when the panel opens"),
      running: tr3("运行中", "執行中", "Running"),
      failed: ctrl.error ?? tr3("报错", "錯誤", "Error"),
    };
    const rows = ctrl.config.devices.map((d) => {
      const driver = TV_BRIDGE_DRIVERS.find((x) => x.id === d.driver);
      return `<li class="cc-field-row" data-tvbridge-device="${esc(d.nativeId)}"><span>${esc(d.name)} · ${esc(driver ? tr3(...driver.label) : d.driver)} · ${esc(d.host)}</span>
        <button type="button" class="cc-btn-secondary" data-tvbridge-remove="${esc(d.nativeId)}">${esc(tr3("移除", "移除", "Remove"))}</button></li>`;
    }).join("");
    const visibleDrivers = visibleTVBridgeDrivers(ctrl.showExperimentalDrivers);
    const firstDriver = visibleDrivers[0]!;
    const options = renderDriverOptions(visibleDrivers, esc);
    const experimentalLabel = tr3("显示实验性协议（未真机验证）", "顯示實驗性協議（未實機驗證）", "Show experimental protocols (unverified on hardware)");
    const secretAttr = firstDriver.secret ? `placeholder="${esc(tr3(...firstDriver.secret))}"` : "hidden";
    body = `
        <div class="cc-field-row" style="margin-top: 6px;">
          <input type="text" data-tvbridge-binary placeholder="C:\\Tools\\mbh-tv-bridge.exe" value="${esc(ctrl.config.binaryPath ?? "")}" aria-label="${esc(tr3("mbh-tv-bridge.exe 路径", "mbh-tv-bridge.exe 路徑", "mbh-tv-bridge.exe path"))}" />
          <input type="text" data-tvbridge-sha placeholder="${esc(tr3("SHA-256 校验值（可选）", "SHA-256 校驗值（選用）", "SHA-256 digest (optional)"))}" value="${esc(ctrl.config.expectedBinarySHA256 ?? "")}" />
        </div>
        <div class="cc-field-row">
          <p class="cc-field-hint" data-tvbridge-status="${ctrl.status}" style="margin: 0;">${esc(status[ctrl.status])}</p>
          <button type="button" class="cc-btn-secondary" data-tvbridge-refresh ${ctrl.isRefreshing ? "disabled" : ""}>${esc(tr3("立即刷新", "立即重新整理", "Refresh Now"))}</button>
        </div>
        <ul class="cc-tvbridge-devices" style="list-style: none; margin: 6px 0; padding: 0;">${rows || `<li class="cc-field-hint">${esc(tr3("尚未添加电视", "尚未新增電視", "No TVs added yet"))}</li>`}</ul>
        <form class="cc-field" data-tvbridge-form>
          <input name="name" required placeholder="${esc(tr3("名称，如 客厅电视", "名稱，如 客廳電視", "Name, e.g. Living Room TV"))}" />
          <input name="room" placeholder="${esc(tr3("房间", "房間", "Room"))}" />
          <select name="driver" data-tvbridge-driver>${options}</select>
          <label class="cc-field-hint" style="display: flex; align-items: center; gap: 6px; margin: 0;">
            <input type="checkbox" data-tvbridge-experimental ${ctrl.showExperimentalDrivers ? "checked" : ""} />
            <span>${esc(experimentalLabel)}</span>
          </label>
          <input name="host" required placeholder="${esc(tr3("IP 地址", "IP 位址", "IP address"))}" />
          <input name="port" inputmode="numeric" data-tvbridge-port placeholder="${esc(tr3("端口，默认 {p}", "連接埠，預設 {p}", "Port, default {p}").replace("{p}", String(firstDriver.port)))}" />
          <input name="mac" placeholder="${esc(tr3("MAC 地址（可选）", "MAC 位址（選用）", "MAC address (optional)"))}" />
          <input name="secret" type="password" autocomplete="off" data-tvbridge-secret ${secretAttr} />
          <button type="submit" class="cc-btn-secondary">${esc(tr3("添加电视", "新增電視", "Add TV"))}</button>
        </form>`;
  }
  return `
    <div class="cc-settings-group-card" data-tvbridge-settings>
      <div class="cc-field" data-settings-anchor="tvBridge">
        <div class="cc-field-row">
          <div>
            <label for="settings-tv-bridge">${esc(title)}</label>
            <p class="cc-field-hint" style="margin: 2px 0 0 0;">${esc(hint)}</p>
          </div>
          <input id="settings-tv-bridge" type="checkbox" data-tvbridge-toggle ${ctrl.enabled ? "checked" : ""} />
        </div>${body}
      </div>
    </div>`;
}

const boundRoots = new WeakSet<HTMLElement>();

/** Delegated listeners on the app root; safe to call after every render. */
export function bindTVBridgeEvents(root: HTMLElement, ctrl: TVBridgeController): void {
  if (boundRoots.has(root)) return;
  boundRoots.add(root);
  root.addEventListener("click", (event) => {
    const target = (event.target as Element | null)?.closest<HTMLElement>("[data-tvbridge-refresh], [data-tvbridge-remove]");
    if (!target || !root.contains(target)) return;
    if (target.dataset.tvbridgeRemove) void ctrl.removeDevice(target.dataset.tvbridgeRemove);
    else void ctrl.refresh();
  });
  root.addEventListener("change", (event) => {
    const input = event.target as HTMLInputElement | HTMLSelectElement | null;
    if (!input) return;
    if (input.matches("[data-tvbridge-toggle]")) ctrl.setEnabled((input as HTMLInputElement).checked);
    else if (input.matches("[data-tvbridge-binary]")) ctrl.setBinaryPath(input.value);
    else if (input.matches("[data-tvbridge-sha]")) ctrl.setExpectedSHA256(input.value);
    else if (input.matches("[data-tvbridge-experimental]")) {
      const checked = (input as HTMLInputElement).checked;
      ctrl.setShowExperimentalDrivers(checked);
      const select = input.closest("form")?.querySelector<HTMLSelectElement>("[data-tvbridge-driver]");
      if (select) {
        const previous = select.value;
        const escHtml = (raw: string) => raw.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
        select.innerHTML = renderDriverOptions(visibleTVBridgeDrivers(checked), escHtml);
        if ([...select.options].some((opt) => opt.value === previous)) select.value = previous;
        syncDriverFormHints(select);
      }
    } else if (input.matches("[data-tvbridge-driver]")) {
      syncDriverFormHints(input as HTMLSelectElement);
    }
  });
  root.addEventListener("submit", (event) => {
    const form = (event.target as Element | null)?.closest<HTMLFormElement>("[data-tvbridge-form]");
    if (!form) return;
    event.preventDefault();
    const field = (name: string) => (form.elements.namedItem(name) as HTMLInputElement | null)?.value ?? "";
    const port = field("port").trim();
    void ctrl.addDevice({
      name: field("name"), roomName: field("room"), driver: field("driver") as TVBridgeDriver, host: field("host"),
      ...(port ? { port: Number(port) } : {}), macAddress: field("mac"), secret: field("secret"),
    });
  });
}
