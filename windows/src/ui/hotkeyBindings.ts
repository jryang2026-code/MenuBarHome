import { IntentReply, ManualControlPolicy } from "../core/assistant.js";
import {
  deviceCanTogglePower,
  isDeviceActiveOn,
  type DeviceIntent,
  type HomeScene,
  type SmartDevice,
} from "../core/models.js";
import { coverMotorRequiresConfirmation } from "./detailDrawers.js";
import { t, tr3 } from "../core/i18n.js";
import { evaluateDeviceEntityWriteGate } from "../core/miAccountControl.js";
import { QUICK_ACTION_PREFIX, quickActionTitle, type QuickActionId } from "../core/quickActions.js";
import { parseGlobalShortcut, withAliases } from "./panelPrefs.js";
import { buildHostCapabilityContext, isDualSourceEnabled } from "./cloudRefresh.js";
import { invokeTauriVoid, isWorkstationLockBlockingControl } from "./transport.js";
import { toggleDeviceForHost } from "./bindEvents.js";
import type { MoodSnapshot } from "../core/moodSnapshot.js";
import { applyMoodForHost } from "./moods.js";
import type { MenuMijiaWindowsApp } from "./app.js";

export const MAX_CUSTOM_HOTKEY_BINDINGS = 8;

export type HotkeyBindingTarget =
  | { readonly kind: "devicePower"; readonly deviceId: string }
  | { readonly kind: "scene"; readonly sceneId: string }
  | { readonly kind: "quickAction"; readonly actionId: QuickActionId }
  | { readonly kind: "mood"; readonly moodId: string };

export interface HotkeyBinding {
  readonly id: string;
  readonly target: HotkeyBindingTarget;
  /** Cached display name from bind time so missing targets still render readably. */
  readonly targetLabel: string;
  /** Canonical shortcut string from `parseGlobalShortcut` (e.g. `Ctrl+Alt+1`). */
  readonly shortcut: string;
}

export type HotkeyConflictKind =
  | "invalid"
  | "panelHotkey"
  | "existingBinding"
  | "systemShortcut"
  | "maxBindingsReached";

export interface HotkeyConflict {
  readonly kind: HotkeyConflictKind;
  readonly message: string;
}

export type HotkeyExecutionOutcome =
  | { readonly status: "executed"; readonly message: string }
  | { readonly status: "blocked"; readonly message: string }
  | { readonly status: "needsConfirmation"; readonly message: string }
  | { readonly status: "cancelled"; readonly message: string }
  | { readonly status: "failed"; readonly message: string }
  | { readonly status: "unavailable"; readonly label: string };

const KNOWN_WINDOWS_SYSTEM_SHORTCUTS: Readonly<Record<string, string>> = {
  "Alt+F4": "Close Window (Alt+F4)",
  "Alt+Tab": "Task Switcher (Alt+Tab)",
  "Alt+Space": "Window Menu (Alt+Space)",
  "Ctrl+Alt+Delete": "Windows Security (Ctrl+Alt+Delete)",
  "Ctrl+Shift+Escape": "Task Manager (Ctrl+Shift+Esc)",
  "Ctrl+Escape": "Start Menu (Ctrl+Esc)",
  "Super+L": "Lock Screen (Win+L)",
  "Super+D": "Show Desktop (Win+D)",
  "Super+E": "File Explorer (Win+E)",
  "Super+R": "Run Dialog (Win+R)",
  "Super+Tab": "Task View (Win+Tab)",
  "Super+Space": "Input Switcher (Win+Space)",
  "Super+I": "Windows Settings (Win+I)",
  "Super+S": "Windows Search (Win+S)",
  "Ctrl+C": "Copy (Ctrl+C)",
  "Ctrl+V": "Paste (Ctrl+V)",
  "Ctrl+X": "Cut (Ctrl+X)",
  "Ctrl+A": "Select All (Ctrl+A)",
  "Ctrl+Z": "Undo (Ctrl+Z)",
  "Ctrl+S": "Save (Ctrl+S)",
  "Ctrl+W": "Close Tab (Ctrl+W)",
  "Ctrl+Q": "Quit (Ctrl+Q)",
};

const QUICK_ACTION_IDS: ReadonlyArray<QuickActionId> = [
  "lightsOff",
  "softNightLight",
  "climateSleepOff",
];

function isQuickActionId(raw: unknown): raw is QuickActionId {
  return raw === "lightsOff" || raw === "softNightLight" || raw === "climateSleepOff";
}

function parseBindingTarget(raw: unknown): HotkeyBindingTarget | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (obj.kind === "devicePower" && typeof obj.deviceId === "string" && obj.deviceId.trim()) {
    return { kind: "devicePower", deviceId: obj.deviceId.trim() };
  }
  if (obj.kind === "scene" && typeof obj.sceneId === "string" && obj.sceneId.trim()) {
    return { kind: "scene", sceneId: obj.sceneId.trim() };
  }
  if (obj.kind === "quickAction" && isQuickActionId(obj.actionId)) {
    return { kind: "quickAction", actionId: obj.actionId };
  }
  if (obj.kind === "mood" && typeof obj.moodId === "string" && obj.moodId.trim()) {
    return { kind: "mood", moodId: obj.moodId.trim() };
  }
  return null;
}

export function normalizeCustomHotkeyBindings(raw: unknown): HotkeyBinding[] {
  if (!Array.isArray(raw)) return [];
  const seenIds = new Set<string>();
  const seenShortcuts = new Set<string>();
  const out: HotkeyBinding[] = [];
  for (const item of raw) {
    if (out.length >= MAX_CUSTOM_HOTKEY_BINDINGS) break;
    if (!item || typeof item !== "object") continue;
    const obj = item as Record<string, unknown>;
    const id = typeof obj.id === "string" ? obj.id.trim() : "";
    if (!id || seenIds.has(id)) continue;
    const target = parseBindingTarget(obj.target);
    if (!target) continue;
    const shortcut = parseGlobalShortcut(obj.shortcut);
    if (!shortcut || seenShortcuts.has(shortcut)) continue;
    const targetLabel =
      typeof obj.targetLabel === "string" && obj.targetLabel.trim()
        ? obj.targetLabel.trim()
        : target.kind === "quickAction"
          ? quickActionTitle(target.actionId)
          : target.kind === "devicePower"
            ? target.deviceId
            : target.kind === "scene"
              ? target.sceneId
              : target.moodId;
    seenIds.add(id);
    seenShortcuts.add(shortcut);
    out.push({ id, target, targetLabel, shortcut });
  }
  return out;
}

export function knownWindowsSystemShortcutName(shortcut: string): string | null {
  const canonical = parseGlobalShortcut(shortcut);
  if (!canonical) return null;
  return KNOWN_WINDOWS_SYSTEM_SHORTCUTS[canonical] ?? null;
}

export function validateCustomHotkeyShortcut(
  rawShortcut: string,
  options: {
    readonly panelShortcut: string;
    readonly checkPanelConflict?: boolean;
    readonly existingBindings: readonly HotkeyBinding[];
    readonly excludingBindingId?: string | null;
  },
): HotkeyConflict | null {
  const canonical = parseGlobalShortcut(rawShortcut);
  if (!canonical) {
    return {
      kind: "invalid",
      message: tr3(
        "需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。",
        "需要至少一個 Ctrl / Alt / Shift / Win，或單按 F1–F20。",
        "Use at least one of Ctrl / Alt / Shift / Win, or a single F1–F20 key.",
      ),
    };
  }
  const systemName = knownWindowsSystemShortcutName(canonical);
  if (systemName) {
    return {
      kind: "systemShortcut",
      message: tr3(
        "与系统快捷键（{name}）冲突，换一个组合。",
        "與系統快捷鍵（{name}）衝突，換一個組合。",
        "Conflicts with a system shortcut ({name}). Choose another combination.",
        { name: systemName },
      ),
    };
  }
  const checkPanel = options.checkPanelConflict ?? true;
  if (checkPanel && parseGlobalShortcut(options.panelShortcut) === canonical) {
    return {
      kind: "panelHotkey",
      message: tr3(
        "与呼出面板的全局快捷键冲突，换一个组合。",
        "與呼出面板的全域快捷鍵衝突，換一個組合。",
        "Conflicts with the dashboard toggle shortcut. Choose another combination.",
      ),
    };
  }
  const duplicate = options.existingBindings.find(
    (b) => b.id !== options.excludingBindingId && parseGlobalShortcut(b.shortcut) === canonical,
  );
  if (duplicate) {
    return {
      kind: "existingBinding",
      message: tr3(
        "已被「{target}」占用，换一个组合。",
        "已被「{target}」佔用，換一個組合。",
        'Already assigned to "{target}". Choose another combination.',
        { target: duplicate.targetLabel },
      ),
    };
  }
  return null;
}

export function isHotkeyBindingTargetAvailable(
  binding: HotkeyBinding,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  moods: readonly MoodSnapshot[] = [],
): boolean {
  const target = binding.target;
  switch (target.kind) {
    case "devicePower": {
      const dev = devices.find((d) => d.id === target.deviceId);
      return Boolean(dev && deviceCanTogglePower(dev));
    }
    case "scene":
      return scenes.some((s) => s.id === target.sceneId);
    case "quickAction":
      return devices.length > 0;
    case "mood":
      return moods.some((m) => m.id === target.moodId);
  }
}

export function resolvedHotkeyBindingLabel(
  binding: HotkeyBinding,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
  moods: readonly MoodSnapshot[] = [],
): string {
  const target = binding.target;
  switch (target.kind) {
    case "devicePower":
      return devices.find((d) => d.id === target.deviceId)?.name ?? binding.targetLabel;
    case "scene":
      return scenes.find((s) => s.id === target.sceneId)?.name ?? binding.targetLabel;
    case "quickAction":
      return quickActionTitle(target.actionId);
    case "mood":
      return moods.find((m) => m.id === target.moodId)?.name ?? binding.targetLabel;
  }
}

export function encodeHotkeyTargetKey(target: HotkeyBindingTarget): string {
  switch (target.kind) {
    case "devicePower":
      return `device:${target.deviceId}`;
    case "scene":
      return `scene:${target.sceneId}`;
    case "quickAction":
      return `quick:${target.actionId}`;
    case "mood":
      return `mood:${target.moodId}`;
  }
}

export function decodeHotkeyTargetKey(raw: string): HotkeyBindingTarget | null {
  if (raw.startsWith("device:")) {
    const deviceId = raw.slice("device:".length).trim();
    return deviceId ? { kind: "devicePower", deviceId } : null;
  }
  if (raw.startsWith("scene:")) {
    const sceneId = raw.slice("scene:".length).trim();
    return sceneId ? { kind: "scene", sceneId } : null;
  }
  if (raw.startsWith("quick:")) {
    const actionId = raw.slice("quick:".length).trim();
    return isQuickActionId(actionId) ? { kind: "quickAction", actionId } : null;
  }
  if (raw.startsWith("mood:")) {
    const moodId = raw.slice("mood:".length).trim();
    return moodId ? { kind: "mood", moodId } : null;
  }
  return null;
}

export function allQuickActionIds(): readonly QuickActionId[] {
  return QUICK_ACTION_IDS;
}

async function notifyIfPanelHidden(body: string): Promise<void> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke || !body.trim()) return;
  try {
    const visible = Boolean(await invoke<boolean>("panel_is_visible"));
    if (visible) return;
    await invoke("send_desktop_notification", {
      title: tr3("快捷热键", "快捷熱鍵", "Global Hotkey"),
      body,
      kind: "safety",
    });
  } catch {
    // Non-fatal: in-panel replyBanner still reflects the result.
  }
}

/**
 * Executes a bound global hotkey through the exact same control path as a panel tap:
 * capability gate, workstation lock-screen block, and high-risk confirmation (never silently
 * executes a high-risk device; no "don't ask again"). Missing targets are a silent no-op.
 */
export async function executeCustomHotkeyBinding(
  host: MenuMijiaWindowsApp,
  bindingId: string,
): Promise<HotkeyExecutionOutcome> {
  const bindings = normalizeCustomHotkeyBindings(host.settings.customHotkeyBindings);
  const binding = bindings.find((b) => b.id === bindingId);
  if (!binding) {
    return { status: "unavailable", label: bindingId };
  }

  const target = binding.target;
  if (target.kind === "devicePower") {
    const dev = host.devices.find((d) => d.id === target.deviceId);
    if (!dev || !deviceCanTogglePower(dev)) {
      return { status: "unavailable", label: binding.targetLabel };
    }
    if (await isWorkstationLockBlockingControl(host)) {
      const msg = tr3(
        "Windows 已锁定，已阻止设备控制。可在设置 → 隐私中关闭此限制。",
        "Windows 已鎖定，已阻止裝置控制。可在設定 → 隱私中關閉此限制。",
        "Windows is locked, so device control is blocked. Turn this off in Settings → Privacy.",
      );
      host.replyBanner = { text: msg, source: tr3("已阻止", "已阻止", "Blocked"), isError: true };
      host.render();
      await notifyIfPanelHidden(msg);
      return { status: "blocked", message: msg };
    }

    const aliased = withAliases(host.layout, host.devices);
    const aliasedDev = aliased.find((d) => d.id === dev.id) ?? dev;
    const isMomentaryPlug =
      dev.kind.kind === "plug" && dev.kind.switchEntityId.startsWith("button.");
    const nextOn = isMomentaryPlug || !isDeviceActiveOn(dev);
    const powerIntent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: nextOn } };
    const stopsMovingCover =
      dev.kind.kind === "cover" &&
      dev.kind.motion !== "stopped" &&
      dev.kind.pauseDescription !== null;
    const hazard =
      dev.kind.kind === "cover"
        ? !stopsMovingCover &&
          coverMotorRequiresConfirmation(dev.kind.subtype, nextOn ? "open" : "close")
        : !stopsMovingCover && ManualControlPolicy.requiresConfirmation(powerIntent, aliased);

    if (hazard) {
      // A high-risk device bound to a hotkey must ALWAYS ask and never silently execute, even if
      // pressed repeatedly within the 8 s window.
      host.clearPendingHighRisk();
      toggleDeviceForHost(host, dev.id);
      const msg =
        host.replyBanner?.text ??
        t("「{action}」属于高风险设备，确认后执行", { action: aliasedDev.name });
      invokeTauriVoid("show_panel_for_url");
      return { status: "needsConfirmation", message: msg };
    }

    const priorBanner = host.replyBanner?.text;
    toggleDeviceForHost(host, dev.id);
    if (host.replyBanner?.isError && host.replyBanner.text !== priorBanner) {
      await notifyIfPanelHidden(host.replyBanner.text);
      return { status: "blocked", message: host.replyBanner.text };
    }
    const summary = t(nextOn ? "已打开{name}" : "已关闭{name}", { name: aliasedDev.name });
    await notifyIfPanelHidden(summary);
    return { status: "executed", message: summary };
  }

  if (target.kind === "scene") {
    const scene = host.scenes.find((s) => s.id === target.sceneId);
    if (!scene) {
      return { status: "unavailable", label: binding.targetLabel };
    }
    if (await isWorkstationLockBlockingControl(host)) {
      const msg = tr3(
        "Windows 已锁定，已阻止设备控制。可在设置 → 隐私中关闭此限制。",
        "Windows 已鎖定，已阻止裝置控制。可在設定 → 隱私中關閉此限制。",
        "Windows is locked, so device control is blocked. Turn this off in Settings → Privacy.",
      );
      host.replyBanner = { text: msg, source: tr3("已阻止", "已阻止", "Blocked"), isError: true };
      host.render();
      await notifyIfPanelHidden(msg);
      return { status: "blocked", message: msg };
    }
    if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
      const gateMsg = evaluateDeviceEntityWriteGate({
        targetKind: "scene",
        targetIdOrEntityId: scene.id,
        resolvedActiveDeviceId: null,
        context: buildHostCapabilityContext(host),
        rejectUnknown: true,
        languagePreference: host.settings.interfaceLanguage,
      });
      if (gateMsg !== null) {
        host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
        host.render();
        await notifyIfPanelHidden(gateMsg);
        return { status: "blocked", message: gateMsg };
      }
    }
    const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
    const reply = IntentReply.describe(intents, host.devices, host.scenes);
    await host.executeIntents(intents, reply, t("0ms 本地直达"), { recordHabits: true });
    const message = host.replyBanner?.text ?? reply;
    await notifyIfPanelHidden(message);
    if (host.replyBanner?.isError) {
      return { status: "blocked", message };
    }
    return { status: "executed", message };
  }

  if (target.kind === "mood") {
    const mood = host.moods.find((m) => m.id === target.moodId);
    if (!mood) {
      return { status: "unavailable", label: binding.targetLabel };
    }
    const outcome = await applyMoodForHost(host, mood.id, { openPanelForModal: true });
    if ("message" in outcome && outcome.message) {
      await notifyIfPanelHidden(outcome.message);
    }
    return outcome;
  }

  // quickAction
  if (host.devices.length === 0) {
    return { status: "unavailable", label: quickActionTitle(target.actionId) };
  }
  if (await isWorkstationLockBlockingControl(host)) {
    const msg = tr3(
      "Windows 已锁定，已阻止设备控制。可在设置 → 隐私中关闭此限制。",
      "Windows 已鎖定，已阻止裝置控制。可在設定 → 隱私中關閉此限制。",
      "Windows is locked, so device control is blocked. Turn this off in Settings → Privacy.",
    );
    host.replyBanner = { text: msg, source: tr3("已阻止", "已阻止", "Blocked"), isError: true };
    host.render();
    await notifyIfPanelHidden(msg);
    return { status: "blocked", message: msg };
  }
  await host.handleNaturalCommand(`${QUICK_ACTION_PREFIX}${target.actionId}`);
  const message = host.replyBanner?.text ?? quickActionTitle(target.actionId);
  await notifyIfPanelHidden(message);
  if (host.replyBanner?.isError) {
    return { status: "blocked", message };
  }
  return { status: "executed", message };
}
