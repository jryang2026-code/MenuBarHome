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
  type QuickActionId,
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

  quickAction(scene: BuiltInURLSceneId): QuickActionId | null {
    switch (scene) {
      case "lightsOff":
      case "softNightLight":
      case "climateSleepOff":
        return scene;
      case "allOff":
      case "undo":
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
}

export function screenLockBlockedMessage(): string {
  return trText(
    "屏幕已锁定，已拦截设备控制指令",
    "Workstation is locked; device control was blocked",
  );
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
      if (resolved.percent === 0) {
        return trText("关闭「{name}」（{room}）", 'Turn off "{name}" ({room})', { name, room });
      }
      return trText(
        "把{name}亮度调到 {percent}%（{room}）",
        "Set {name} brightness to {percent}% ({room})",
        { name, percent: resolved.percent, room },
      );
    }
    case "colorTemp": {
      const name = displayNameFor(resolved.device, host);
      return trText(
        "把{name}色温调到 {kelvin}K",
        "Set {name} colour temperature to {kelvin}K",
        { name, kelvin: resolved.kelvin },
      );
    }
    case "temperature": {
      const name = displayNameFor(resolved.device, host);
      const temp = formatTemperature(resolved.celsius);
      return trText("把{name}温度调到 {temp}", "Set {name} to {temp}", { name, temp });
    }
    case "fan": {
      const name = displayNameFor(resolved.device, host);
      if (resolved.percent !== null) {
        return trText("把{name}风速调到 {percent}%", "Set {name} fan speed to {percent}%", {
          name,
          percent: resolved.percent,
        });
      }
      return trText(
        "把{name}风速切换到「{preset}」",
        'Set {name} fan mode to "{preset}"',
        { name, preset: resolved.preset ?? "" },
      );
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

async function runIntentOnDevice(
  host: AppURLCommandHost,
  deviceId: string,
  intent: DeviceIntent,
  summary: string,
  labelForHighRisk: string,
): Promise<{ readonly message: string; readonly isError: boolean }> {
  const dev = host.devices.find((d) => d.id === deviceId);
  if (!dev) {
    return {
      message: trText("设备已不在面板中", "The device is no longer available"),
      isError: true,
    };
  }
  if (!dev.isOnline) {
    return {
      message: trText("{name} 当前离线", "{name} is offline", { name: displayNameFor(dev, host) }),
      isError: true,
    };
  }
  const commands = IntentValidator.commandsForIntent(intent, dev);
  const firstCommand = commands[0];
  if (!firstCommand) {
    return {
      message: trText("该设备不支持此控制项", "This device does not support that control"),
      isError: true,
    };
  }

  // High-risk confirmation (`ManualControlPolicy`) always applies, even with a valid `bridgeToken`.
  if (requiresHighRiskArm(dev, intent, firstCommand, host.devices)) {
    const actionKey = JSON.stringify(firstCommand);
    const armed = host.pendingHighRisk;
    const isArmedAndValid =
      armed !== null &&
      armed.deviceId === dev.id &&
      armed.actionKey === actionKey &&
      armed.sourceRevision === host.sourceRevision &&
      armed.expiresAtMs > Date.now();
    if (!isArmedAndValid) {
      host.setPendingHighRisk({
        deviceId: dev.id,
        actionKey,
        expiresAtMs: Date.now() + 8000,
        sourceRevision: host.sourceRevision,
        confirm: { command: firstCommand, summary, intent },
      });
      host.expandedDeviceId = dev.id;
      const promptMsg = trText(
        "「{action}」属于高风险设备，请在面板中确认或再次触发",
        '"{action}" is high-risk; confirm in the panel or trigger once more',
        { action: labelForHighRisk },
      );
      host.showExternalToast(promptMsg, false);
      await host.revealPanelForExternalUrl();
      return { message: promptMsg, isError: true };
    }
    host.clearPendingHighRisk();
  }

  for (let i = 0; i < commands.length; i += 1) {
    const cmd = commands[i]!;
    if (i === 0) {
      const prevBanner = host.replyBanner;
      await host.executeSingleCommand(dev, cmd, summary, intent);
      if (host.replyBanner !== prevBanner && host.replyBanner?.isError) {
        return { message: host.replyBanner.text, isError: true };
      }
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
      trText(
        "链接里的设备或场景不存在，或尚未加载",
        "The device or scene in the link is missing or not loaded yet",
      ),
      true,
    );
    return;
  }

  const controlsDevice = appURLCommandControlsDevice(envelope.command);
  if (controlsDevice && (await host.isControlBlockedByScreenLock())) {
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

  switch (resolved.kind) {
    case "focus": {
      host.focusDeviceFromUrl(resolved.device.id);
      const name = displayNameFor(resolved.device, host);
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
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        { targetId: dev.id, operation: { kind: "power", isOn: nextOn } },
        summary,
        actionLabel,
      );
      finish(outcome.message, outcome.isError);
      return;
    }
    case "power": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      const actionLabel = resolved.isOn
        ? trText("打开 {name}", "Turn on {name}", { name })
        : trText("关闭 {name}", "Turn off {name}", { name });
      const summary = resolved.isOn
        ? trText("已打开 {name}", "Turned on {name}", { name })
        : trText("已关闭 {name}", "Turned off {name}", { name });
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        { targetId: dev.id, operation: { kind: "power", isOn: resolved.isOn } },
        summary,
        actionLabel,
      );
      finish(outcome.message, outcome.isError);
      return;
    }
    case "brightness": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      const summary =
        resolved.percent === 0
          ? trText("已关闭 {name}", "Turned off {name}", { name })
          : trText("已将{name}亮度设为 {percent}%", "Set {name} brightness to {percent}%", {
              name,
              percent: resolved.percent,
            });
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        {
          targetId: dev.id,
          operation:
            resolved.percent === 0
              ? { kind: "power", isOn: false }
              : { kind: "brightness", percent: resolved.percent },
        },
        summary,
        summary,
      );
      finish(outcome.message, outcome.isError);
      return;
    }
    case "colorTemp": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      const summary = trText(
        "已将{name}色温设为 {kelvin}K",
        "Set {name} colour temperature to {kelvin}K",
        { name, kelvin: resolved.kelvin },
      );
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        { targetId: dev.id, operation: { kind: "colorTemperature", kelvin: resolved.kelvin } },
        summary,
        summary,
      );
      finish(outcome.message, outcome.isError);
      return;
    }
    case "temperature": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      const tempText = formatTemperature(resolved.celsius);
      const summary = trText("已将{name}温度设为 {temp}", "Set {name} to {temp}", {
        name,
        temp: tempText,
      });
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        { targetId: dev.id, operation: { kind: "targetTemperature", celsius: resolved.celsius } },
        summary,
        summary,
      );
      finish(outcome.message, outcome.isError);
      return;
    }
    case "fan": {
      const dev = resolved.device;
      const name = displayNameFor(dev, host);
      const speed = resolved.percent !== null ? String(resolved.percent) : (resolved.preset ?? "");
      const summary =
        resolved.percent !== null
          ? trText("已将{name}风速设为 {percent}%", "Set {name} fan speed to {percent}%", {
              name,
              percent: resolved.percent,
            })
          : trText("已将{name}风速设为 {preset}", "Set {name} fan mode to {preset}", {
              name,
              preset: speed,
            });
      const outcome = await runIntentOnDevice(
        host,
        dev.id,
        { targetId: dev.id, operation: { kind: "fanSpeed", speed } },
        summary,
        summary,
      );
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
      await host.handleNaturalCommand(resolved.text, false);
      if (host.pendingConsent) {
        if (isTrustedBridge) await host.revealPanelForExternalUrl();
        finish(
          trText(
            "这条指令需要云端 AI。请在面板里确认后重试。",
            "This command needs cloud AI. Confirm it in the panel and try again.",
          ),
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
