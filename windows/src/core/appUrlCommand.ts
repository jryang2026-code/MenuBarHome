import {
  IntentValidator,
  ManualControlPolicy,
} from "./assistant.js";
import {
  allOffTargets,
  deviceCanTogglePower,
  isDeviceActiveOn,
  type DeviceCommand,
  type DeviceIntent,
  type HomeScene,
  type SmartDevice,
} from "./models.js";
import {
  quickActionTitle,
  trText,
} from "./quickActions.js";
import type { RaycastCommandFeedback } from "./raycastSnapshot.js";
import { formatTemperature } from "./temperature.js";

export type AppURLCommand =
  | { readonly kind: "toggle"; readonly deviceId: string }
  | { readonly kind: "scene"; readonly name: string }
  | { readonly kind: "ask"; readonly text: string }
  | { readonly kind: "power"; readonly deviceId: string; readonly isOn: boolean }
  | { readonly kind: "brightness"; readonly deviceId: string; readonly percent: number }
  | { readonly kind: "colorTemp"; readonly deviceId: string; readonly kelvin: number }
  | { readonly kind: "temperature"; readonly deviceId: string; readonly celsius: number }
  | { readonly kind: "fan"; readonly deviceId: string; readonly percent: number | null; readonly preset: string | null }
  | { readonly kind: "focus"; readonly deviceId: string };

export function appURLCommandControlsDevice(command: AppURLCommand): boolean {
  return command.kind !== "focus";
}

export interface AppURLCommandEnvelope {
  readonly command: AppURLCommand;
  readonly token?: string;
  readonly requestId?: string;
}

export type BuiltInURLSceneId =
  | "lightsOff"
  | "softNightLight"
  | "climateSleepOff"
  | "allOff"
  | "undo";

export const BuiltInURLScene = {
  resolve(raw: string): BuiltInURLSceneId | null {
    const trimmed = raw.trim();
    if (!trimmed) return null;
    const stripped = trimmed.toLowerCase().startsWith("quick:")
      ? trimmed.slice("quick:".length).trim()
      : trimmed;
    switch (stripped.toLowerCase()) {
      case "lightsoff":
      case "lights_off":
      case "全屋关灯":
        return "lightsOff";
      case "softnightlight":
      case "soft_night_light":
      case "柔和夜灯":
        return "softNightLight";
      case "climatesleepoff":
      case "climate_sleep_off":
      case "关温控风扇":
      case "睡眠关空调":
        return "climateSleepOff";
      case "alloff":
      case "all_off":
      case "一键全关":
      case "全关":
        return "allOff";
      case "undo":
      case "撤销上一步":
      case "撤销":
        return "undo";
      default:
        return null;
    }
  },
  displayTitle(scene: BuiltInURLSceneId): string {
    switch (scene) {
      case "lightsOff":
      case "softNightLight":
      case "climateSleepOff":
        return quickActionTitle(scene);
      case "allOff":
        return trText("一键全关", "Turn All Off");
      case "undo":
        return trText("撤销上一步", "Undo Last Action");
    }
  },
} as const;

const TRUE_WORDS = new Set(["1", "true", "on", "yes"]);
const FALSE_WORDS = new Set(["0", "false", "off", "no"]);

function parseBooleanWord(raw: string | undefined): boolean | null {
  if (raw === undefined) return null;
  const word = raw.trim().toLowerCase();
  if (TRUE_WORDS.has(word)) return true;
  if (FALSE_WORDS.has(word)) return false;
  return null;
}

function parseStrictInt(raw: string | undefined, min: number, max: number): number | null {
  if (raw === undefined) return null;
  const trimmed = raw.trim();
  if (!/^[+-]?\d+$/.test(trimmed)) return null;
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value) || value < min || value > max) return null;
  return value;
}

function parseStrictDecimal(raw: string | undefined, min: number, max: number): number | null {
  if (raw === undefined) return null;
  const trimmed = raw.trim();
  if (!/^[+-]?(?:\d+\.?\d*|\.\d+)$/.test(trimmed)) return null;
  const value = Number(trimmed);
  if (!Number.isFinite(value) || value < min || value > max) return null;
  return value;
}

function parseRawQuery(rawQuery: string | undefined): Record<string, string> | null {
  const out: Record<string, string> = {};
  if (!rawQuery) return out;
  for (const part of rawQuery.split("&")) {
    if (!part) continue;
    const eqIndex = part.indexOf("=");
    if (eqIndex <= 0) continue;
    let key: string;
    let val: string;
    try {
      key = decodeURIComponent(part.slice(0, eqIndex)).trim().toLowerCase();
      val = decodeURIComponent(part.slice(eqIndex + 1)).trim();
    } catch {
      return null;
    }
    if (!key || !val || Object.prototype.hasOwnProperty.call(out, key)) continue;
    out[key] = val;
  }
  return out;
}

export const AppURLParser = {
  scheme: "menumijia",
  maximumAskLength: 500,
  maximumNameLength: 200,
  maximumTokenLength: 200,
  maximumRequestIdLength: 120,
  maximumURLLength: 4096,
  brightnessRange: [0, 100] as const,
  colorTempRange: [1000, 20000] as const,
  celsiusRange: [-30, 100] as const,

  parse(rawUrl: string): AppURLCommand | null {
    return this.parseEnvelope(rawUrl)?.command ?? null;
  },

  parseEnvelope(rawUrl: string): AppURLCommandEnvelope | null {
    if (typeof rawUrl !== "string") return null;
    const trimmedUrl = rawUrl.trim();
    if (!trimmedUrl || trimmedUrl.length > this.maximumURLLength) return null;
    if (/[\r\n\0]/.test(trimmedUrl)) return null;

    const match = /^([a-zA-Z][a-zA-Z0-9+.-]*):(?:\/\/|\/)?([^?#]*)(?:\?([^#]*))?(?:#.*)?$/.exec(
      trimmedUrl,
    );
    if (!match) return null;
    const [, schemePart, rawRoute = "", rawQuery] = match;
    if (!schemePart || schemePart.toLowerCase() !== this.scheme) return null;

    const strippedRoute = rawRoute.replace(/^\/+|\/+$/g, "");
    if (!strippedRoute || strippedRoute.includes("/")) return null;
    const route = strippedRoute.toLowerCase().replace(/[-_]/g, "");

    const query = parseRawQuery(rawQuery);
    if (!query) return null;

    let token: string | undefined;
    if (query.token !== undefined) {
      if (query.token.length > this.maximumTokenLength) return null;
      token = query.token;
    }

    let requestId: string | undefined;
    const rawReqId = query.id ?? query.request_id ?? query.requestid ?? query.req;
    if (rawReqId !== undefined) {
      if (rawReqId.length > this.maximumRequestIdLength) return null;
      requestId = rawReqId;
    }

    let command: AppURLCommand;
    switch (route) {
      case "toggle": {
        const deviceId = query.device;
        if (!deviceId || deviceId.length > this.maximumNameLength) return null;
        command = { kind: "toggle", deviceId };
        break;
      }
      case "scene": {
        const name = query.name;
        if (!name || name.length > this.maximumNameLength) return null;
        command = { kind: "scene", name };
        break;
      }
      case "ask": {
        const text = query.text;
        if (!text || text.length > this.maximumAskLength) return null;
        command = { kind: "ask", text };
        break;
      }
      case "power": {
        const deviceId = query.device;
        const isOn = parseBooleanWord(query.on ?? query.state);
        if (!deviceId || deviceId.length > this.maximumNameLength || isOn === null) return null;
        command = { kind: "power", deviceId, isOn };
        break;
      }
      case "brightness": {
        const deviceId = query.device;
        const percent = parseStrictInt(
          query.percent,
          this.brightnessRange[0],
          this.brightnessRange[1],
        );
        if (!deviceId || deviceId.length > this.maximumNameLength || percent === null) return null;
        command = { kind: "brightness", deviceId, percent };
        break;
      }
      case "colortemp": {
        const deviceId = query.device;
        const kelvin = parseStrictInt(
          query.kelvin ?? query.value,
          this.colorTempRange[0],
          this.colorTempRange[1],
        );
        if (!deviceId || deviceId.length > this.maximumNameLength || kelvin === null) return null;
        command = { kind: "colorTemp", deviceId, kelvin };
        break;
      }
      case "temperature": {
        const deviceId = query.device;
        const celsius = parseStrictDecimal(
          query.celsius ?? query.value,
          this.celsiusRange[0],
          this.celsiusRange[1],
        );
        if (!deviceId || deviceId.length > this.maximumNameLength || celsius === null) return null;
        command = { kind: "temperature", deviceId, celsius };
        break;
      }
      case "fan": {
        const deviceId = query.device;
        if (!deviceId || deviceId.length > this.maximumNameLength) return null;
        const rawPercent = query.percent;
        const rawPreset = query.preset;
        const percent = parseStrictInt(rawPercent, 1, 100);
        const preset =
          rawPreset !== undefined && rawPreset.length <= this.maximumNameLength ? rawPreset : null;
        if (rawPercent !== undefined && percent === null) return null;
        if (rawPreset !== undefined && preset === null) return null;
        if ((percent !== null) === (preset !== null)) return null;
        command = { kind: "fan", deviceId, percent, preset };
        break;
      }
      case "focus": {
        const deviceId = query.device;
        if (!deviceId || deviceId.length > this.maximumNameLength) return null;
        command = { kind: "focus", deviceId };
        break;
      }
      default:
        return null;
    }

    return {
      command,
      ...(token !== undefined ? { token } : {}),
      ...(requestId !== undefined ? { requestId } : {}),
    };
  },
} as const;

export const URLDirectControl = {
  minimumBridgeTokenLength: 16,

  isValidBridgeToken(providedToken?: string, expectedToken?: string): boolean {
    const provided = providedToken?.trim() ?? "";
    const expected = expectedToken?.trim() ?? "";
    if (provided.length < this.minimumBridgeTokenLength) return false;
    const encoder = new TextEncoder();
    const lhs = encoder.encode(provided);
    const rhs = encoder.encode(expected);
    if (lhs.length !== rhs.length) return false;
    let diff = 0;
    for (let i = 0; i < lhs.length; i += 1) {
      diff |= (lhs[i] ?? 0) ^ (rhs[i] ?? 0);
    }
    return diff === 0;
  },

  requiresConfirmation(options: {
    readonly allowDirectControl: boolean;
    readonly providedToken?: string;
    readonly expectedToken?: string;
  }): boolean {
    if (options.allowDirectControl) return false;
    if (this.isValidBridgeToken(options.providedToken, options.expectedToken)) return false;
    return true;
  },
} as const;

export function formatAppURLCommandLabel(command: AppURLCommand): string {
  switch (command.kind) {
    case "toggle":
      return `toggle:${command.deviceId}`;
    case "scene":
      return `scene:${command.name}`;
    case "ask":
      return `ask:${command.text}`;
    case "power":
      return `power:${command.deviceId}:${command.isOn ? "on" : "off"}`;
    case "brightness":
      return `brightness:${command.deviceId}:${command.percent}`;
    case "colorTemp":
      return `color-temp:${command.deviceId}:${command.kelvin}`;
    case "temperature":
      return `temperature:${command.deviceId}:${formatTemperature(command.celsius).replace(/°[CF]$/, "")}`;
    case "fan":
      return command.percent !== null
        ? `fan:${command.deviceId}:${command.percent}`
        : `fan:${command.deviceId}:${command.preset ?? ""}`;
    case "focus":
      return `focus:${command.deviceId}`;
  }
}

type ResolvedURLTarget =
  | { readonly kind: "toggle"; readonly device: SmartDevice }
  | { readonly kind: "scene"; readonly scene: HomeScene }
  | { readonly kind: "builtInScene"; readonly builtIn: BuiltInURLSceneId }
  | { readonly kind: "ask"; readonly text: string }
  | { readonly kind: "power"; readonly device: SmartDevice; readonly isOn: boolean }
  | { readonly kind: "brightness"; readonly device: SmartDevice; readonly percent: number }
  | { readonly kind: "colorTemp"; readonly device: SmartDevice; readonly kelvin: number }
  | { readonly kind: "temperature"; readonly device: SmartDevice; readonly celsius: number }
  | {
      readonly kind: "fan";
      readonly device: SmartDevice;
      readonly percent: number | null;
      readonly preset: string | null;
    }
  | { readonly kind: "focus"; readonly device: SmartDevice };

export interface AppURLCommandHost {
  readonly devices: SmartDevice[];
  readonly scenes: HomeScene[];
  readonly sourceRevision: number;
  readonly settings: {
    readonly enableRaycastIntegration: boolean;
    readonly allowDirectURLControl: boolean;
    readonly blockControlWhileLocked: boolean;
  };
  readonly layout: {
    readonly aliases: Readonly<Record<string, string>>;
    readonly roomAliases?: Readonly<Record<string, string>>;
  };
  readonly pendingHighRisk: {
    readonly deviceId: string;
    readonly actionKey: string;
    readonly expiresAtMs: number;
    readonly sourceRevision: number;
    readonly confirm?: {
      readonly command: DeviceCommand;
      readonly summary: string;
      readonly intent: DeviceIntent;
      readonly promptLabel?: string;
    };
  } | null;
  readonly replyBanner: {
    readonly text: string;
    readonly source: string;
    readonly isError?: boolean;
  } | null;
  readonly pendingConsent: unknown;
  expandedDeviceId: string | null;

  waitForInitialSnapshotIfNeeded?(): Promise<void>;
  getActiveRaycastBridgeToken(): string | undefined;
  isControlBlockedByScreenLock(): Promise<boolean>;
  requestExternalUrlConfirmation(args: {
    readonly description: string;
    readonly commandLabel: string;
    readonly requestId?: string;
    readonly sourceRevision: number;
  }): Promise<boolean>;
  /**
   * Optional modal confirmation prompt for high-risk device actions arriving with a valid
   * `bridgeToken` (CLI / MCP / Raycast). When provided, `onOpenURL` awaits the user's explicit
   * Confirm / Cancel click in the panel and executes immediately on Confirm (`isError: false`);
   * when omitted, `onOpenURL` falls back to arming `pendingHighRisk` and returning a prompt error.
   */
  openExternalUrlConfirmPrompt?(args: {
    readonly device: SmartDevice;
    readonly description: string;
    readonly actionLabel: string;
    readonly summary: string;
    readonly commandLabel: string;
    readonly intent: DeviceIntent;
    readonly command: DeviceCommand;
    readonly requestId?: string;
    readonly sourceRevision: number;
  }): Promise<boolean>;
  revealPanelForExternalUrl(): Promise<void>;
  setPendingHighRisk(next: NonNullable<AppURLCommandHost["pendingHighRisk"]>): void;
  clearPendingHighRisk(): void;
  showExternalToast(message: string, isError: boolean): void;
  recordRaycastCommandFeedback(feedback: Omit<RaycastCommandFeedback, "completedAt">): void;
  executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower?: boolean,
  ): Promise<void>;
  applyCommand(command: DeviceCommand, readBackPower?: boolean): Promise<boolean>;
  handleNaturalCommand(rawInput: string, fromScheduled?: boolean): Promise<void>;
  executeBuiltInSceneFromUrl(
    scene: BuiltInURLSceneId,
  ): Promise<{ readonly message: string; readonly isError: boolean }>;
  focusDeviceFromUrl(deviceId: string): void;
  /** False for cards the panel hides (e.g. offline devices while "hide offline" is on). */
  isDeviceVisibleInPanel?(deviceId: string): boolean;
}

export function screenLockBlockedMessage(): string {
  return trText( "屏幕已锁定，已拦截设备控制指令", "Workstation is locked; device control was blocked");
}

function displayNameFor(device: SmartDevice, host: AppURLCommandHost): string {
  return host.layout.aliases[device.id]?.trim() || device.name;
}

function displayRoomFor(device: SmartDevice, host: AppURLCommandHost): string {
  return host.layout.roomAliases?.[device.roomId]?.trim() || device.roomName;
}

function resolveTarget(command: AppURLCommand, host: AppURLCommandHost): ResolvedURLTarget | null {
  switch (command.kind) {
    case "toggle": {
      const dev = host.devices.find(
        (d) =>
          (d.id === command.deviceId ||
            d.name === command.deviceId ||
            displayNameFor(d, host) === command.deviceId) &&
          deviceCanTogglePower(d),
      );
      return dev ? { kind: "toggle", device: dev } : null;
    }
    case "scene": {
      if (command.name.toLowerCase().startsWith("quick:")) {
        const builtIn = BuiltInURLScene.resolve(command.name);
        if (builtIn) return { kind: "builtInScene", builtIn };
      }
      const scene = host.scenes.find(
        (s) => s.name === command.name || s.id === command.name || s.entityId === command.name,
      );
      if (scene) return { kind: "scene", scene };
      const builtIn = BuiltInURLScene.resolve(command.name);
      return builtIn ? { kind: "builtInScene", builtIn } : null;
    }
    case "ask":
      return { kind: "ask", text: command.text };
    case "power": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev ? { kind: "power", device: dev, isOn: command.isOn } : null;
    }
    case "brightness": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev ? { kind: "brightness", device: dev, percent: command.percent } : null;
    }
    case "colorTemp": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev ? { kind: "colorTemp", device: dev, kelvin: command.kelvin } : null;
    }
    case "temperature": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev ? { kind: "temperature", device: dev, celsius: command.celsius } : null;
    }
    case "fan": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev
        ? { kind: "fan", device: dev, percent: command.percent, preset: command.preset }
        : null;
    }
    case "focus": {
      const dev = host.devices.find((d) => d.id === command.deviceId);
      return dev ? { kind: "focus", device: dev } : null;
    }
  }
}

function describeResolvedTarget(resolved: ResolvedURLTarget, host: AppURLCommandHost): string {
  switch (resolved.kind) {
    case "toggle": {
      const name = displayNameFor(resolved.device, host);
      const room = displayRoomFor(resolved.device, host);
      const verb = isDeviceActiveOn(resolved.device)
        ? trText("关闭", "Turn off")
        : trText("打开", "Turn on");
      return trText("{verb}「{name}」（{room}）", '{verb} "{name}" ({room})', { verb, name, room });
    }
    case "scene":
      return trText("触发场景「{name}」", 'Run scene "{name}"', { name: resolved.scene.name });
    case "builtInScene":
      return trText("执行快捷动作「{name}」", 'Run quick action "{name}"', {
        name: BuiltInURLScene.displayTitle(resolved.builtIn),
      });
    case "ask":
      return trText("执行指令：「{text}」", 'Run command: "{text}"', { text: resolved.text });
    case "power": {
      const name = displayNameFor(resolved.device, host);
      const room = displayRoomFor(resolved.device, host);
      const verb = resolved.isOn ? trText("打开", "Turn on") : trText("关闭", "Turn off");
      return trText("{verb}「{name}」（{room}）", '{verb} "{name}" ({room})', { verb, name, room });
    }
    case "brightness": {
      const name = displayNameFor(resolved.device, host);
      const room = displayRoomFor(resolved.device, host);
      if (resolved.percent === 0) { return trText("关闭「{name}」（{room}）", 'Turn off "{name}" ({room})', { name, room }); }
      return trText( "把{name}亮度调到 {percent}%（{room}）", "Set {name} brightness to {percent}% ({room})", { name, percent: resolved.percent, room });
    }
    case "colorTemp": {
      const name = displayNameFor(resolved.device, host);
      const spec = resolved.device.kind.kind === "light" ? resolved.device.kind : null;
      const kelvin = spec
        ? Math.max(spec.minKelvin, Math.min(spec.maxKelvin, Math.round(resolved.kelvin)))
        : Math.round(resolved.kelvin);
      return trText( "把{name}色温调到 {kelvin}K", "Set {name} colour temperature to {kelvin}K", { name, kelvin });
    }
    case "temperature": {
      const name = displayNameFor(resolved.device, host);
      const spec = resolved.device.kind.kind === "climate" ? resolved.device.kind : null;
      const target = spec
        ? snapTemperature(resolved.celsius, spec.minTemp, spec.maxTemp, spec.step)
        : resolved.celsius;
      const temp = formatTemperature(target);
      return trText("把{name}温度调到 {temp}", "Set {name} to {temp}", { name, temp });
    }
    case "fan": {
      const name = displayNameFor(resolved.device, host);
      if (resolved.percent !== null) {
        const clamped = Math.max(1, Math.min(100, Math.round(resolved.percent)));
        return trText("把{name}风速调到 {percent}%", "Set {name} fan speed to {percent}%", {
          name,
          percent: clamped,
        });
      }
      return trText( "把{name}风速切换到「{preset}」", 'Set {name} fan mode to "{preset}"', { name, preset: resolved.preset ?? "" });
    }
    case "focus": {
      const name = displayNameFor(resolved.device, host);
      return trText("打开「{name}」详情", 'Open "{name}" details', { name });
    }
  }
}

function requiresHighRiskArm(
  device: SmartDevice,
  intent: DeviceIntent,
  command: DeviceCommand,
  devices: readonly SmartDevice[],
): boolean {
  const stopsMovingCover =
    device.kind.kind === "cover" &&
    device.kind.motion !== "stopped" &&
    device.kind.pauseDescription !== null &&
    command.kind === "setSelectOption" &&
    command.option === device.kind.pauseDescription;
  if (stopsMovingCover) return false;
  return ManualControlPolicy.requiresConfirmation(intent, devices);
}

/** Matches `RaycastControls.swift` fan presets: exact (case-insensitive) first, then substring. */
export function matchFanPreset(presets: readonly string[], wanted: string): string | null {
  const lowered = wanted.trim().toLowerCase();
  if (lowered === "") return null;
  return (
    presets.find((p) => p.toLowerCase() === lowered) ??
    presets.find((p) => p.toLowerCase().includes(lowered) || lowered.includes(p.toLowerCase())) ??
    null
  );
}

/** Snaps to the thermostat's step grid inside `[minTemp, maxTemp]` (`RaycastControls.swift`). */
export function snapTemperature(celsius: number, min: number, max: number, step: number): number {
  const clamped = Math.max(min, Math.min(max, celsius));
  if (!(step > 0)) return clamped;
  const snapped = min + Math.round((clamped - min) / step) * step;
  return Math.round(Math.max(min, Math.min(max, snapped)) * 100) / 100;
}

interface URLBridgeContext {
  readonly isTrustedBridge: boolean;
  readonly commandLabel: string;
  readonly requestId?: string;
}

export interface DirectAskPresetResult {
  readonly handled: boolean;
  readonly message: string;
  readonly isError: boolean;
}

async function runIntentOnDevice(
  host: AppURLCommandHost,
  deviceId: string,
  intent: DeviceIntent,
  summary: string,
  labelForHighRisk: string,
  options: {
    readonly commands?: readonly DeviceCommand[];
    readonly riskIntent?: DeviceIntent;
    readonly bridgeContext?: URLBridgeContext;
  } = {},
): Promise<{ readonly message: string; readonly isError: boolean }> {
  let dev = host.devices.find((d) => d.id === deviceId);
  if (!dev) { return { message: trText("设备已不在面板中", "The device is no longer available"), isError: true}; }
  if (!dev.isOnline) { return { message: trText("{name} 当前离线", "{name} is offline", { name: displayNameFor(dev, host) }), isError: true}; }
  const commands = options.commands ?? IntentValidator.commandsForIntent(intent, dev);
  const firstCommand = commands[0];
  if (!firstCommand) { return { message: trText("该设备不支持此控制项", "This device does not support that control"), isError: true}; }

  const initialDev = dev;
  const aliasedDevices = host.devices.map((d) => {
    const alias = host.layout.aliases[d.id]?.trim();
    return alias ? { ...d, name: alias } : d;
  });
  const effectiveDev = aliasedDevices.find((d) => d.id === initialDev.id) ?? initialDev;

  if (requiresHighRiskArm(effectiveDev, options.riskIntent ?? intent, firstCommand, aliasedDevices)) {
    if ( options.bridgeContext?.isTrustedBridge && typeof host.openExternalUrlConfirmPrompt === "function" ) {
      const revisionBeforePrompt = host.sourceRevision;
      host.focusDeviceFromUrl(dev.id);
      await host.revealPanelForExternalUrl();
      const confirmed = await host.openExternalUrlConfirmPrompt({ device: effectiveDev, description: labelForHighRisk, actionLabel: labelForHighRisk, summary, commandLabel: options.bridgeContext.commandLabel, intent, command: firstCommand, ...(options.bridgeContext.requestId ? { requestId: options.bridgeContext.requestId } : {}), sourceRevision: revisionBeforePrompt});
      if (!confirmed || host.sourceRevision !== revisionBeforePrompt) {
        host.clearPendingHighRisk();
        return {
          message: trText("已取消「{name}」的操作", 'Cancelled the action for "{name}"', {
            name: displayNameFor(dev, host),
          }),
          isError: true,
        };
      }
      if (await host.isControlBlockedByScreenLock()) { return { message: screenLockBlockedMessage(), isError: true }; }
      const latestDev = host.devices.find((d) => d.id === deviceId);
      if (!latestDev) { return { message: trText("设备已不在面板中", "The device is no longer available"), isError: true}; }
      if (!latestDev.isOnline) {
        return {
          message: trText("{name} 当前离线", "{name} is offline", {
            name: displayNameFor(latestDev, host),
          }),
          isError: true,
        };
      }
      dev = latestDev;
      host.clearPendingHighRisk();
    } else {
      const actionKey = JSON.stringify(firstCommand);
      host.setPendingHighRisk({ deviceId: dev.id, actionKey, expiresAtMs: Date.now() + 8000, sourceRevision: host.sourceRevision, confirm: { command: firstCommand, summary, intent, promptLabel: labelForHighRisk }});
      host.focusDeviceFromUrl(dev.id);
      const promptMsg = trText( "「{action}」属于高风险设备，请在面板中确认", '"{action}" is high-risk; confirm in the panel', { action: labelForHighRisk });
      host.showExternalToast(promptMsg, false);
      await host.revealPanelForExternalUrl();
      return { message: promptMsg, isError: true };
    }
  }

  for (let i = 0; i < commands.length; i += 1) {
    const cmd = commands[i]!;
    if (i === 0) {
      const prevBanner = host.replyBanner;
      await host.executeSingleCommand(dev, cmd, summary, intent);
      if (host.replyBanner !== prevBanner && host.replyBanner?.isError) { return { message: host.replyBanner.text, isError: true }; }
    } else {
      const ok = await host.applyCommand(cmd);
      if (!ok) {
        return {
          message:
            host.replyBanner?.text ??
            trText("{name} 响应失败", "{name} failed to respond", { name: displayNameFor(dev, host) }),
          isError: true,
        };
      }
    }
  }
  return { message: summary, isError: false };
}

function firstCaptureInText(text: string, patterns: readonly RegExp[]): string | null {
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    const captured = match?.[1]?.trim();
    if (captured) return captured;
  }
  return null;
}

function twoCapturesInText(
  text: string,
  patterns: readonly RegExp[],
): { readonly first: string; readonly second: string } | null {
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    const first = match?.[1]?.trim();
    const second = match?.[2]?.trim();
    if (first && second) return { first, second };
  }
  return null;
}

const GENERIC_ASK_NOUNS_BY_KIND: Readonly<Record<string, readonly string[]>> = {
  light: ["灯", "灯具", "台灯", "主灯", "吸顶灯", "夜灯", "light", "lamp"],
  vacuum: ["扫地机", "扫地机器人", "清洁机器人", "洗地机", "机器人", "vacuum", "robot vacuum", "robovac", "vac"],
  cover: ["窗帘", "纱帘", "卷帘", "百叶窗", "curtain", "blinds", "shade", "cover"],
  fan: ["风扇", "电风扇", "电扇", "落地扇", "循环扇", "空气循环扇", "fan"],
};

function findUniqueAskDevice(
  host: AppURLCommandHost,
  rawQuery: string,
  predicate: (device: SmartDevice) => boolean,
): SmartDevice | null {
  let clean = rawQuery.trim();
  for (const prefix of ["把", "将", "让", "给", "的"]) {
    if (clean.startsWith(prefix)) {
      clean = clean.slice(prefix.length).trim();
    }
  }
  clean = clean.replace(/^the\s+/i, "").trim();
  if (clean.endsWith("的")) {
    clean = clean.slice(0, -1).trim();
  }
  if (!clean) return null;

  const candidates = host.devices.filter(predicate);
  if (candidates.length === 0) return null;

  const targetLower = clean.toLowerCase();
  const exact = candidates.filter((dev) => {
    const aliasName = displayNameFor(dev, host);
    const aliasRoom = displayRoomFor(dev, host);
    const keys = [ dev.id, aliasName, dev.name, `${aliasRoom}${aliasName}`, `${aliasRoom} ${aliasName}`, `${dev.roomName}${dev.name}`, `${dev.roomName} ${dev.name}`];
    return keys.some((k) => k.trim().toLowerCase() === targetLower);
  });
  if (exact.length === 1) return exact[0]!;

  const substring = candidates.filter((dev) => {
    const aliasName = displayNameFor(dev, host);
    const aliasRoom = displayRoomFor(dev, host);
    if (!aliasName && !dev.name) return false;
    const keys = [ aliasName, dev.name, `${aliasRoom}${aliasName}`, `${aliasRoom} ${aliasName}`, `${dev.roomName}${dev.name}`, `${dev.roomName} ${dev.name}`];
    return keys.some((k) => k.trim().toLowerCase().includes(targetLower));
  });
  if (substring.length === 1) return substring[0]!;

  const firstKind = candidates[0]?.kind.kind ?? "";
  const genericNouns = GENERIC_ASK_NOUNS_BY_KIND[firstKind] ?? [];
  if (genericNouns.some((n) => n.toLowerCase() === targetLower)) { return candidates.length === 1 ? candidates[0]! : null; }
  const byRoomAndCategory = candidates.filter((dev) => {
    const aliasRoom = displayRoomFor(dev, host).trim();
    const rawRoom = dev.roomName.trim();
    return genericNouns.some((noun) => {
      const n = noun.toLowerCase();
      return (
        (aliasRoom !== "" && `${aliasRoom}${n}`.toLowerCase() === targetLower) ||
        (aliasRoom !== "" && `${aliasRoom} ${n}`.toLowerCase() === targetLower) ||
        (rawRoom !== "" && `${rawRoom}${n}`.toLowerCase() === targetLower) ||
        (rawRoom !== "" && `${rawRoom} ${n}`.toLowerCase() === targetLower)
      );
    });
  });
  if (byRoomAndCategory.length === 1) return byRoomAndCategory[0]!;

  return null;
}

function looksScheduledOrCompoundAsk(trimmed: string): boolean {
  if (/^(?:\d+|[一二两三四五六七八九十半刻]+)\s*(?:秒|分钟|分|小时|钟头|刻钟|s|sec|min|hr|hour)/i.test(trimmed)) { return true; }
  if (/后(?:再)?\s*(?:打开|开启|关闭|关上|启动|暂停|回充|把|将|让|设为|调到)/.test(trimmed)) { return true; }
  if (/\bin\s+\d+\s*(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b/i.test(trimmed)) { return true; }
  return false;
}

/**
 * Deterministically executes single-device companion presets arriving via `menumijia://ask?text=...`
 * without requiring cloud AI (`RaycastControls.executeRaycastDirectCommand` parity on macOS):
 * - Single-light soft night light / moonlight (`15% · 2700K`);
 * - Cover / curtain position %, open, and close;
 * - Fan speed percentage and preset mode (`自动` / `睡眠` / `静音` / `最爱` / English modes);
 * - Vacuum start, pause, and dock (`回充` / `返回基站` / `dock`).
 */
export async function executeDirectAskPreset(
  rawText: string,
  host: AppURLCommandHost,
  bridgeContext?: URLBridgeContext,
): Promise<DirectAskPresetResult> {
  const trimmed = rawText.trim();
  if (!trimmed || looksScheduledOrCompoundAsk(trimmed)) { return { handled: false, message: "", isError: false }; }

  const isLight = (d: SmartDevice): boolean => d.kind.kind === "light";
  const bareMoonlight =
    /^(?:请|帮我|麻烦)?(?:开启|打开|设为|调到|调成|切换为)?\s*(?:柔和)?(?:月光|夜灯)(?:模式)?$/i.test(trimmed) ||
    /^(?:please\s+)?(?:enable\s+|turn\s+on\s+)?(?:soft\s+night\s*light|moonlight(?:\s+mode)?)$/i.test(trimmed);
  const moonlightTarget = bareMoonlight
    ? null
    : firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:把|将)?\s*(.+?)\s*(?:调到|设为|调成|变成)\s*15%\s*(?:亮度)?\s*(?:[·,，/\s]\s*)?2700\s*[kK]$/, /^(?:请|帮我|麻烦)?(?:把|将)?\s*(.+?)\s*(?:设为|调到|调成|开启|打开|切换为)\s*(?:柔和)?(?:月光|夜灯)(?:模式)?$/, /^(?:柔和)?(?:月光|夜灯)(?:模式)?\s+(.+)$/, /^(?:please\s+)?(?:set|turn|switch|dim)\s+(.+?)\s+to\s+(?:soft\s+)?(?:moonlight|night\s*light)(?:\s+mode)?$/i, /^(?:please\s+)?(?:set|dim)\s+(.+?)\s+to\s+15%\s*(?:brightness)?\s*(?:@\s*|at\s*|and\s*|·\s*)?2700\s*k$/i, /^(?:soft\s+night\s*light|moonlight(?:\s+mode)?)\s+(.+)$/i]);
  const singleLightCandidates = bareMoonlight ? host.devices.filter(isLight) : [];
  const dev = bareMoonlight
    ? singleLightCandidates.length === 1
      ? singleLightCandidates[0]!
      : null
    : moonlightTarget
      ? findUniqueAskDevice(host, moonlightTarget, isLight)
      : null;
  if (dev && dev.kind.kind === "light") {
    {
      const name = displayNameFor(dev, host);
      if (!dev.isOnline) { return { handled: true, message: trText("{name} 当前离线", "{name} is offline", { name }), isError: true}; }
      const spec = dev.kind;
      const commands: DeviceCommand[] = [];
      if (spec.brightnessWritable !== false) {
        commands.push({ kind: "setLightBrightness", entityId: spec.entityId, percent: 15 });
      }
      if (spec.colorWritable !== false) {
        const kelvin = Math.max(spec.minKelvin, Math.min(spec.maxKelvin, 2700));
        commands.push({ kind: "setLightColorTemp", entityId: spec.entityId, kelvin });
      } else {
        const nightEffect = spec.availableEffects.find(
          (eff) =>
            eff.toLowerCase() === "night" ||
            eff.toLowerCase().includes("moon") ||
            eff.includes("夜"),
        );
        if (nightEffect) {
          commands.push({ kind: "setLightEffect", entityId: spec.entityId, effect: nightEffect });
        }
      }
      if (commands.length === 0 && spec.powerWritable !== false) {
        commands.push({ kind: "setLightPower", entityId: spec.entityId, isOn: true });
      }
      if (commands.length === 0) {
        return {
          handled: true,
          message: trText( "{name} 不支持柔和月光调节", "{name} does not support Moonlight mode", { name }),
          isError: true,
        };
      }
      const summary = trText( "已将{name}设为柔和月光（15% · 2700K）", "Set {name} to Moonlight (15% · 2700K)", { name });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "brightness", percent: 15 } }, summary, summary, { commands, ...(bridgeContext ? { bridgeContext } : {}) });
      return { handled: true, message: outcome.message, isError: outcome.isError };
    }
  }

  const runDirectCover = async (dev: SmartDevice, rawPercent: number): Promise<DirectAskPresetResult> => {
    if (dev.kind.kind !== "cover") return { handled: false, message: "", isError: false };
    const name = displayNameFor(dev, host);
    if (!dev.isOnline) { return { handled: true, message: trText("{name} 当前离线", "{name} is offline", { name }), isError: true}; }
    const spec = dev.kind;
    const clamped = Math.max(0, Math.min(100, Math.round(rawPercent)));
    let cmd: DeviceCommand | null = null;
    if (clamped === 100) {
      if (!spec.positionWritable && spec.openDescription) {
        cmd = { kind: "setSelectOption", entityId: spec.entityId, option: spec.openDescription };
      } else if (spec.positionWritable) {
        cmd = { kind: "setNumberValue", entityId: spec.entityId, value: 100 };
      } else if (spec.openDescription) {
        cmd = { kind: "setSelectOption", entityId: spec.entityId, option: spec.openDescription };
      }
    } else if (clamped === 0) {
      if (!spec.positionWritable && spec.closeDescription) {
        cmd = { kind: "setSelectOption", entityId: spec.entityId, option: spec.closeDescription };
      } else if (spec.positionWritable) {
        cmd = { kind: "setNumberValue", entityId: spec.entityId, value: 0 };
      } else if (spec.closeDescription) {
        cmd = { kind: "setSelectOption", entityId: spec.entityId, option: spec.closeDescription };
      }
    } else if (spec.positionWritable) {
      cmd = { kind: "setNumberValue", entityId: spec.entityId, value: clamped };
    }
    if (!cmd) { return { handled: true, message: trText("{name} 不支持该位置调节", "{name} does not support that position", { name }), isError: true}; }
    const summary =
      clamped === 100
        ? trText("已打开{name}", "Opened {name}", { name })
        : clamped === 0
          ? trText("已关闭{name}", "Closed {name}", { name })
          : trText("已将{name}开到 {percent}%", "Set {name} to {percent}%", { name, percent: clamped });
    const actionLabel =
      clamped === 100
        ? trText("打开 {name}", "Open {name}", { name })
        : clamped === 0
          ? trText("关闭 {name}", "Close {name}", { name })
          : summary;
    const isOn = clamped > 0;
    const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "power", isOn } }, summary, actionLabel, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn } }, ...(bridgeContext ? { bridgeContext } : {})});
    return { handled: true, message: outcome.message, isError: outcome.isError };
  };

  const coverPercentMatch = twoCapturesInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:把|将)?\s*(.+?)\s*(?:开到|调到|设为|拉到)\s*(\d{1,3})\s*%$/, /^(?:please\s+)?set\s+(.+?)\s+(?:position\s+)?to\s+(\d{1,3})\s*%$/i]);
  if (coverPercentMatch) {
    const parsedPct = Number.parseInt(coverPercentMatch.second, 10);
    const dev = findUniqueAskDevice(host, coverPercentMatch.first, (d) => d.kind.kind === "cover");
    if (dev && Number.isFinite(parsedPct)) { return runDirectCover(dev, parsedPct); }
  }

  const coverOpenTarget = firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:打开|开启|拉开|全开)\s*(.+)$/, /^(?:please\s+)?open\s+(.+)$/i]);
  if (coverOpenTarget) {
    const dev = findUniqueAskDevice(host, coverOpenTarget, (d) => d.kind.kind === "cover");
    if (dev) { return runDirectCover(dev, 100); }
  }

  const coverCloseTarget = firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:关闭|关上|拉上|合上|全关)\s*(.+)$/, /^(?:please\s+)?close\s+(.+)$/i]);
  if (coverCloseTarget) {
    const dev = findUniqueAskDevice(host, coverCloseTarget, (d) => d.kind.kind === "cover");
    if (dev) { return runDirectCover(dev, 0); }
  }

  const fanPercentMatch = twoCapturesInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:把|将)?\s*(.+?)\s*(?:风速|风量|转速)\s*(?:调到|设为|调成)\s*(\d{1,3})\s*%$/, /^(?:please\s+)?set\s+(.+?)\s+(?:fan\s+)?speed\s+to\s+(\d{1,3})\s*%$/i]);
  if (fanPercentMatch) {
    const parsedPct = Number.parseInt(fanPercentMatch.second, 10);
    const dev = findUniqueAskDevice(host, fanPercentMatch.first, (d) => d.kind.kind === "fan");
    if (dev && dev.kind.kind === "fan" && Number.isFinite(parsedPct)) {
      const name = displayNameFor(dev, host);
      if (!dev.isOnline) { return { handled: true, message: trText("{name} 当前离线", "{name} is offline", { name }), isError: true}; }
      if (dev.kind.speedWritable === false) {
        return {
          handled: true,
          message: trText( "{name} 不支持风速百分比调节", "{name} does not support fan speed percentage", { name }),
          isError: true,
        };
      }
      const clamped = Math.max(1, Math.min(100, parsedPct));
      const summary = trText( "已将{name}风速调到 {percent}%", "Set {name} fan speed to {percent}%", { name, percent: clamped });
      const cmd: DeviceCommand = { kind: "setFanPercentage", entityId: dev.kind.entityId, percent: clamped};
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "fanSpeed", speed: String(clamped) } }, summary, summary, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn: true } }, ...(bridgeContext ? { bridgeContext } : {})});
      return { handled: true, message: outcome.message, isError: outcome.isError };
    }
  }

  const fanPresetMatch = twoCapturesInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:把|将)?\s*(.+?)\s*(?:设为|调到|调成|切换为)\s*(自动|睡眠|静音|最爱)\s*(?:模式|档)?$/, /^(?:please\s+)?set\s+(.+?)\s+to\s+(auto|sleep|silent|favorite)(?:\s+mode)?$/i]);
  if (fanPresetMatch) {
    const dev = findUniqueAskDevice(host, fanPresetMatch.first, (d) => d.kind.kind === "fan");
    if (dev && dev.kind.kind === "fan") {
      const name = displayNameFor(dev, host);
      if (!dev.isOnline) { return { handled: true, message: trText("{name} 当前离线", "{name} is offline", { name }), isError: true}; }
      const modeWord = fanPresetMatch.second;
      const canonical =
        modeWord === "自动"
          ? "auto"
          : modeWord === "睡眠" || modeWord === "静音" || modeWord.toLowerCase() === "silent"
            ? "sleep"
            : modeWord === "最爱"
              ? "favorite"
              : modeWord.toLowerCase();
      const normalizedOp = IntentValidator.normalize({ kind: "fanSpeed", speed: canonical }, dev);
      const matchedPreset =
        (normalizedOp?.kind === "fanSpeed" ? normalizedOp.speed : null) ??
        matchFanPreset(dev.kind.availablePresetModes, canonical) ??
        (canonical === "sleep" ? matchFanPreset(dev.kind.availablePresetModes, "silent") : null) ??
        (canonical === "auto" ? "Auto" : canonical === "sleep" ? "Sleep" : "Favorite");
      const summary = trText( "已将{name}设为{mode}模式", "Set {name} to {preset} mode", { name, mode: modeWord, preset: matchedPreset });
      const cmd: DeviceCommand = { kind: "setFanPresetMode", entityId: dev.kind.entityId, presetMode: matchedPreset};
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "fanSpeed", speed: matchedPreset } }, summary, summary, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn: true } }, ...(bridgeContext ? { bridgeContext } : {})});
      return { handled: true, message: outcome.message, isError: outcome.isError };
    }
  }

  const isVacuum = (d: SmartDevice): boolean => d.kind.kind === "vacuum";
  const runDirectVacuum = async (
    dev: SmartDevice,
    action: "start" | "pause" | "returnToBase",
  ): Promise<DirectAskPresetResult> => {
    if (dev.kind.kind !== "vacuum") return { handled: false, message: "", isError: false };
    const name = displayNameFor(dev, host);
    if (!dev.isOnline) { return { handled: true, message: trText("{name} 当前离线", "{name} is offline", { name }), isError: true}; }
    if (dev.kind.actionsWritable === false) {
      return {
        handled: true,
        message: trText( "{name} 不支持该清扫动作", "{name} does not support that vacuum action", { name }),
        isError: true,
      };
    }
    const summary =
      action === "start"
        ? trText("已启动{name}清扫", "Started {name}", { name })
        : action === "pause"
          ? trText("已暂停{name}", "Paused {name}", { name })
          : trText("已让{name}返回基站回充", "Sent {name} back to dock", { name });
    const cmd: DeviceCommand = { kind: "vacuumAction", entityId: dev.kind.entityId, action};
    const isOn = action === "start";
    const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "power", isOn } }, summary, summary, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn } }, ...(bridgeContext ? { bridgeContext } : {})});
    return { handled: true, message: outcome.message, isError: outcome.isError };
  };

  const allVacuums = host.devices.filter(isVacuum);
  const singleVacuum = allVacuums.length === 1 ? allVacuums[0]! : null;

  if ( singleVacuum && (/^(?:请|帮我|麻烦)?暂停清扫$/.test(trimmed) || /^(?:please\s+)?pause\s+cleaning$/i.test(trimmed)) ) { return runDirectVacuum(singleVacuum, "pause"); }

  const vacuumPauseTarget = firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:暂停清扫|暂停)\s*(.+)$/, /^(?:请|帮我|麻烦)?(?:把|将|让)?\s*(.+?)\s*(?:暂停清扫|暂停)$/, /^(?:please\s+)?pause(?:\s+cleaning(?:\s+on)?)?\s+(.+)$/i]);
  if (vacuumPauseTarget) {
    const dev = findUniqueAskDevice(host, vacuumPauseTarget, isVacuum);
    if (dev) { return runDirectVacuum(dev, "pause"); }
  }

  if ( singleVacuum && (/^(?:请|帮我|麻烦)?(?:返回基站回充|返回基站|回充|回座|回去充电|回桩)$/.test(trimmed) || /^(?:please\s+)?(?:dock|return\s+to\s+(?:base|dock))$/i.test(trimmed)) ) { return runDirectVacuum(singleVacuum, "returnToBase"); }

  const vacuumDockTarget = firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:让|把|将)?\s*(.+?)\s*(?:返回基站回充|返回基站|回充|回座|回去充电|回桩)$/, /^(?:请|帮我|麻烦)?(?:返回基站回充|返回基站|回充|回座|回桩)\s*(.+)$/, /^(?:please\s+)?(?:dock|return\s+to\s+(?:base|dock))\s+(.+)$/i, /^(?:please\s+)?(?:send|return)\s+(.+?)\s+(?:back\s+)?to\s+(?:base|dock)$/i, /^(.+?)\s+dock$/i]);
  if (vacuumDockTarget) {
    const dev = findUniqueAskDevice(host, vacuumDockTarget, isVacuum);
    if (dev) { return runDirectVacuum(dev, "returnToBase"); }
  }

  if ( singleVacuum && (/^(?:请|帮我|麻烦)?(?:开始清扫|启动清扫)$/.test(trimmed) || /^(?:please\s+)?start\s+cleaning$/i.test(trimmed)) ) { return runDirectVacuum(singleVacuum, "start"); }

  const vacuumStartTarget = firstCaptureInText(trimmed, [ /^(?:请|帮我|麻烦)?(?:打开|开启|启动|开始清扫|启动清扫)\s*(.+)$/, /^(?:请|帮我|麻烦)?(?:让|把|将)?\s*(.+?)\s*(?:开始清扫|启动清扫)$/, /^(?:please\s+)?start(?:\s+cleaning(?:\s+with)?)?\s+(.+)$/i]);
  if (vacuumStartTarget) {
    const dev = findUniqueAskDevice(host, vacuumStartTarget, isVacuum);
    if (dev) { return runDirectVacuum(dev, "start"); }
  }

  return { handled: false, message: "", isError: false };
}

/**
 * Handles an incoming `menumijia://` URL on Windows, enforcing:
 * 1. Strict `AppURLParser` schema/length/range validation;
 * 2. Workstation lock-screen guard (`blockControlWhileLocked`);
 * 3. Constant-time `bridgeToken` verification or explicit single-run confirmation modal;
 * 4. `ManualControlPolicy` high-risk device confirmation even when `bridgeToken` is valid;
 * 5. Immediate `lastCommandFeedback` write-back to `raycast-snapshot.json`.
 */
export async function onOpenURL(rawUrl: string, host: AppURLCommandHost): Promise<void> {
  const envelope = AppURLParser.parseEnvelope(rawUrl);
  if (!envelope) {
    const msg = trText("无法识别的控制链接", "Unrecognized control link");
    host.showExternalToast(msg, true);
    host.recordRaycastCommandFeedback({
      command: "invalid",
      message: msg,
      isError: true,
    });
    return;
  }

  const commandLabel = formatAppURLCommandLabel(envelope.command);
  const finish = (message: string, isError: boolean) => {
    host.showExternalToast(message, isError);
    host.recordRaycastCommandFeedback({
      ...(envelope.requestId ? { requestId: envelope.requestId } : {}),
      command: commandLabel,
      message,
      isError,
    });
  };

  if (host.waitForInitialSnapshotIfNeeded) {
    await host.waitForInitialSnapshotIfNeeded();
  }

  const initialResolved = resolveTarget(envelope.command, host);
  if (!initialResolved) {
    finish(
      trText( "链接里的设备或场景不存在，或尚未加载", "The device or scene in the link is missing or not loaded yet"),
      true,
    );
    return;
  }

  const controlsDevice = appURLCommandControlsDevice(envelope.command);
  // `focus` is gated too: a locked workstation must not reveal or scroll to a card (RaycastControls parity).
  if (await host.isControlBlockedByScreenLock()) {
    finish(screenLockBlockedMessage(), true);
    return;
  }

  const expectedToken = host.getActiveRaycastBridgeToken();
  const isTrustedBridge = URLDirectControl.isValidBridgeToken(envelope.token, expectedToken);
  const needsConfirmation =
    controlsDevice &&
    URLDirectControl.requiresConfirmation({
      allowDirectControl: host.settings.allowDirectURLControl,
      providedToken: envelope.token,
      expectedToken,
    });

  const revisionBeforeConfirm = host.sourceRevision;
  if (needsConfirmation) {
    await host.revealPanelForExternalUrl();
    const approved = await host.requestExternalUrlConfirmation({
      description: describeResolvedTarget(initialResolved, host),
      commandLabel,
      ...(envelope.requestId ? { requestId: envelope.requestId } : {}),
      sourceRevision: revisionBeforeConfirm,
    });
    if (!approved || host.sourceRevision !== revisionBeforeConfirm) {
      host.recordRaycastCommandFeedback({
        ...(envelope.requestId ? { requestId: envelope.requestId } : {}),
        command: commandLabel,
        message: trText("已取消外部链接执行", "Cancelled external link execution"),
        isError: true,
      });
      return;
    }
    if (await host.isControlBlockedByScreenLock()) {
      finish(screenLockBlockedMessage(), true);
      return;
    }
  } else if (!isTrustedBridge && controlsDevice) {
    await host.revealPanelForExternalUrl();
  }

  const resolved = resolveTarget(envelope.command, host);
  if (!resolved) {
    finish(
      trText("设备或场景已不在面板中", "The device or scene is no longer available"),
      true,
    );
    return;
  }

  const bridgeContext: URLBridgeContext = {
    isTrustedBridge,
    commandLabel,
    ...(envelope.requestId ? { requestId: envelope.requestId } : {}),
  };

  switch (resolved.kind) {
    case "focus": {
      const name = displayNameFor(resolved.device, host);
      if (host.isDeviceVisibleInPanel && !host.isDeviceVisibleInPanel(resolved.device.id)) {
        finish(
          trText("{name} 在面板里被隐藏了", "{name} is hidden in the panel", { name }),
          true,
        );
        return;
      }
      host.focusDeviceFromUrl(resolved.device.id);
      finish(trText("已定位到 {name}", "Focused {name}", { name }), false);
      await host.revealPanelForExternalUrl();
      return;
    }
    case "toggle": {
      const dev = resolved.device;
      const isMomentary =
        dev.kind.kind === "plug" && dev.kind.switchEntityId.startsWith("button.");
      const nextOn = isMomentary || !isDeviceActiveOn(dev);
      const name = displayNameFor(dev, host);
      const actionLabel = isMomentary
        ? trText("触发 {name}", "Trigger {name}", { name })
        : nextOn
          ? trText("打开 {name}", "Turn on {name}", { name })
          : trText("关闭 {name}", "Turn off {name}", { name });
      const summary = isMomentary
        ? trText("已触发 {name}", "Triggered {name}", { name })
        : nextOn
          ? trText("已打开 {name}", "Turned on {name}", { name })
          : trText("已关闭 {name}", "Turned off {name}", { name });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "power", isOn: nextOn } }, summary, actionLabel, { bridgeContext });
      finish(outcome.message, outcome.isError);
      return;
    }
    case "power": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      if (!deviceCanTogglePower(dev)) {
        finish(
          trText("{name} 没有可直接开关的功能", "{name} has no direct power switch", { name }),
          true,
        );
        return;
      }
      const isMomentary =
        dev.kind.kind === "plug" && dev.kind.switchEntityId.startsWith("button.");
      if (isMomentary && !resolved.isOn) {
        finish(
          trText("{name} 是按钮类设备，只能触发", "{name} is a button device and can only be triggered", { name }),
          true,
        );
        return;
      }
      if (dev.kind.kind === "cover") {
        const spec = dev.kind;
        const isOn = resolved.isOn;
        // Already travelling the way the link asks for is satisfied; any other motion is a
        // direction change the motor has to be told explicitly.
        if ((isOn && spec.motion === "opening") || (!isOn && spec.motion === "closing")) {
          const already = isOn
            ? trText("{name} 正在打开", "{name} is already opening", { name })
            : trText("{name} 正在关闭", "{name} is already closing", { name });
          finish(already, false);
          return;
        }
        if ( spec.motion === "stopped" && spec.positionPercent !== null && ((isOn && spec.positionPercent >= 100) || (!isOn && spec.positionPercent <= 0)) ) {
          const already = isOn
            ? trText("{name} 已经是打开状态", "{name} is already open", { name })
            : trText("{name} 已经是关闭状态", "{name} is already closed", { name });
          finish(already, false);
          return;
        }
        const actionLabel = isOn
          ? trText("打开 {name}", "Turn on {name}", { name })
          : trText("关闭 {name}", "Turn off {name}", { name });
        const summary = isOn
          ? trText("已打开 {name}", "Turned on {name}", { name })
          : trText("已关闭 {name}", "Turned off {name}", { name });

        let command: DeviceCommand | null = null;
        if (spec.positionWritable) {
          command = { kind: "setNumberValue", entityId: spec.entityId, value: isOn ? 100 : 0 };
        } else {
          const option = isOn ? spec.openDescription : spec.closeDescription;
          if (option) {
            command = { kind: "setSelectOption", entityId: spec.entityId, option };
          }
        }
        if (!command) {
          finish(trText("该设备不支持此控制项", "This device does not support that control"), true);
          return;
        }
        const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "power", isOn } }, summary, actionLabel, { commands: [command], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn } }, bridgeContext});
        finish(outcome.message, outcome.isError);
        return;
      }
      if (!isMomentary && dev.isOnline && isDeviceActiveOn(dev) === resolved.isOn) {
        const already = resolved.isOn
          ? trText("{name} 已经是打开状态", "{name} is already on", { name })
          : trText("{name} 已经是关闭状态", "{name} is already off", { name });
        finish(already, false);
        return;
      }
      const actionLabel = isMomentary
        ? trText("触发 {name}", "Trigger {name}", { name })
        : resolved.isOn
          ? trText("打开 {name}", "Turn on {name}", { name })
          : trText("关闭 {name}", "Turn off {name}", { name });
      const summary = isMomentary
        ? trText("已触发 {name}", "Triggered {name}", { name })
        : resolved.isOn
          ? trText("已打开 {name}", "Turned on {name}", { name })
          : trText("已关闭 {name}", "Turned off {name}", { name });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "power", isOn: resolved.isOn } }, summary, actionLabel, { bridgeContext });
      finish(outcome.message, outcome.isError);
      return;
    }
    case "brightness": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      // `percent=0` maps to power-off below, so without this a stray slider value would switch
      // off a plug or heater (`RaycastControls.executeRaycastBrightness` refuses the same way).
      if (dev.kind.kind !== "light") {
        finish(trText("{name} 不是灯具", "{name} is not a light", { name }), true);
        return;
      }
      const summary =
        resolved.percent === 0
          ? trText("已关闭 {name}", "Turned off {name}", { name })
          : trText("已将{name}亮度设为 {percent}%", "Set {name} brightness to {percent}%", {
              name,
              percent: resolved.percent,
            });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: resolved.percent === 0 ? { kind: "power", isOn: false } : { kind: "brightness", percent: resolved.percent }}, summary, summary, { bridgeContext });
      finish(outcome.message, outcome.isError);
      return;
    }
    case "colorTemp": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      if (dev.kind.kind !== "light") {
        finish(trText("{name} 不是灯具", "{name} is not a light", { name }), true);
        return;
      }
      if (dev.kind.colorWritable === false) {
        finish(
          trText("{name} 不支持调节色温", "{name} does not support colour temperature", { name }),
          true,
        );
        return;
      }
      const clamped = Math.max(dev.kind.minKelvin, Math.min(dev.kind.maxKelvin, Math.round(resolved.kelvin)));
      const summary = trText( "已将{name}色温设为 {kelvin}K", "Set {name} colour temperature to {kelvin}K", { name, kelvin: clamped });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "colorTemperature", kelvin: clamped } }, summary, summary, { bridgeContext });
      finish(outcome.message, outcome.isError);
      return;
    }
    case "temperature": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      if (dev.kind.kind !== "climate") {
        finish(trText("{name} 不是温控设备", "{name} is not a climate device", { name }), true);
        return;
      }
      if (dev.kind.temperatureWritable === false) {
        finish(
          trText("{name} 不支持设定温度", "{name} does not accept a target temperature", { name }),
          true,
        );
        return;
      }
      const target = snapTemperature(resolved.celsius, dev.kind.minTemp, dev.kind.maxTemp, dev.kind.step);
      const targetText = formatTemperature(target);
      if (target === dev.kind.targetTemperature) {
        finish(
          trText( "{name} 的目标温度已经是 {targetText}", "{name} is already set to {targetText}", { name, targetText }),
          false,
        );
        return;
      }
      const summary = trText("已将{name}温度设为 {temp}", "Set {name} to {temp}", {
        name,
        temp: targetText,
      });
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "targetTemperature", celsius: target } }, summary, summary, { bridgeContext });
      finish(outcome.message, outcome.isError);
      return;
    }
    case "fan": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      if (dev.kind.kind !== "fan") {
        finish(
          trText("{name} 不是风扇或空气净化器", "{name} is not a fan or purifier", { name }),
          true,
        );
        return;
      }
      if (dev.kind.speedWritable === false) {
        finish(
          trText("{name} 不支持调节风速", "{name} does not support fan speed", { name }),
          true,
        );
        return;
      }
      if (resolved.percent !== null) {
        const clamped = Math.max(1, Math.min(100, Math.round(resolved.percent)));
        const summary = trText("已将{name}风速设为 {percent}%", "Set {name} fan speed to {percent}%", {
          name,
          percent: clamped,
        });
        const cmd: DeviceCommand = { kind: "setFanPercentage", entityId: dev.kind.entityId, percent: clamped};
        const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "fanSpeed", speed: String(clamped) } }, summary, summary, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn: true } }, bridgeContext});
        finish(outcome.message, outcome.isError);
        return;
      }
      if (resolved.preset === null) {
        finish(
          trText("缺少风速百分比或档位", "A fan speed or preset is required"),
          true,
        );
        return;
      }
      const wanted = resolved.preset;
      const normalizedOp = IntentValidator.normalize({ kind: "fanSpeed", speed: wanted }, dev);
      const matched =
        (normalizedOp?.kind === "fanSpeed" ? normalizedOp.speed : null) ??
        matchFanPreset(dev.kind.availablePresetModes, wanted);
      if (!matched) {
        const options = dev.kind.availablePresetModes.slice(0, 6).join(", ");
        finish(
          trText( "{name} 没有「{wanted}」档位，可选：{options}", '{name} has no "{wanted}" mode; available: {options}', { name, wanted, options }),
          true,
        );
        return;
      }
      const summary = trText("已将{name}风速设为 {preset}", "Set {name} fan mode to {preset}", {
        name,
        preset: matched,
      });
      const cmd: DeviceCommand = { kind: "setFanPresetMode", entityId: dev.kind.entityId, presetMode: matched};
      const outcome = await runIntentOnDevice( host, dev.id, { targetId: dev.id, operation: { kind: "fanSpeed", speed: matched } }, summary, summary, { commands: [cmd], riskIntent: { targetId: dev.id, operation: { kind: "power", isOn: true } }, bridgeContext});
      finish(outcome.message, outcome.isError);
      return;
    }
    case "scene": {
      const ok = await host.applyCommand({
        kind: "activateScene",
        entityId: resolved.scene.entityId,
      });
      const message = ok
        ? trText("已触发场景：{name}", "Activated scene: {name}", { name: resolved.scene.name })
        : trText("场景「{name}」执行失败", 'Scene "{name}" failed', { name: resolved.scene.name });
      finish(message, !ok);
      return;
    }
    case "builtInScene": {
      const outcome = await host.executeBuiltInSceneFromUrl(resolved.builtIn);
      finish(outcome.message, outcome.isError);
      return;
    }
    case "ask": {
      const directPreset = await executeDirectAskPreset(resolved.text, host, bridgeContext);
      if (directPreset.handled) {
        finish(directPreset.message, directPreset.isError);
        return;
      }
      await host.handleNaturalCommand(resolved.text, false);
      if (host.pendingConsent) {
        if (isTrustedBridge) await host.revealPanelForExternalUrl();
        finish(
          trText( "这条指令需要云端 AI。请在面板里确认后重试。", "This command needs cloud AI. Confirm it in the panel and try again."),
          true,
        );
        return;
      }
      const banner = host.replyBanner;
      if (banner) {
        const needsTap = banner.source === "需要确认" || banner.source === "Confirmation needed";
        if (needsTap && isTrustedBridge) {
          await host.revealPanelForExternalUrl();
        }
        finish(banner.text, Boolean(banner.isError || needsTap));
        return;
      }
      finish(
        trText("没有找到可执行的设备操作", "No matching device actions"),
        true,
      );
      return;
    }
  }
}

export { allOffTargets };
