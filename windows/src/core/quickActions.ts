import { speechLocale } from "./i18n.js";
import type { DeviceCommand, DeviceIntent, SmartDevice } from "./models.js";

/**
 * Locale-reactive copy helper for strings owned outside `i18n.ts` (`w1-drawers` boundary).
 * Reads `speechLocale()` so `setLanguage("en" | "zh-Hans")` switches copy immediately.
 */
export function trText(
  zh: string,
  en: string,
  params?: Readonly<Record<string, string | number>>,
): string {
  const template = speechLocale().toLowerCase().startsWith("en") ? en : zh;
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (_match, key: string) =>
    Object.prototype.hasOwnProperty.call(params, key) ? String(params[key]) : `{${key}}`,
  );
}

export type QuickActionId = "lightsOff" | "softNightLight" | "climateSleepOff";

export const QUICK_ACTION_PREFIX = "quick:";

export interface BuiltInQuickActionDescriptor {
  readonly id: QuickActionId;
  readonly title: string;
  readonly tint: "amber" | "indigo" | "cyan";
  readonly command: string;
}

export function quickActionTitle(id: QuickActionId): string {
  switch (id) {
    case "lightsOff":
      return trText("全屋关灯", "All Lights Off");
    case "softNightLight":
      return trText("柔和夜灯", "Soft Night Light");
    case "climateSleepOff":
      return trText("关温控风扇", "Sleep Climate Off");
  }
}

export function parseQuickActionCommand(raw: string): QuickActionId | null {
  const trimmed = raw.trim();
  if (!trimmed.startsWith(QUICK_ACTION_PREFIX)) return null;
  const id = trimmed.slice(QUICK_ACTION_PREFIX.length);
  if (id === "lightsOff" || id === "softNightLight" || id === "climateSleepOff") {
    return id;
  }
  return null;
}

export function supportsLightsOff(dev: SmartDevice): boolean {
  return dev.isOnline && dev.kind.kind === "light" && dev.kind.powerWritable !== false;
}

export function supportsSoftNightLight(dev: SmartDevice): boolean {
  return (
    dev.isOnline &&
    dev.kind.kind === "light" &&
    dev.kind.brightnessWritable !== false &&
    dev.kind.colorWritable !== false
  );
}

export function supportsClimateSleepOff(dev: SmartDevice): boolean {
  if (!dev.isOnline) return false;
  if (dev.kind.kind === "climate") return dev.kind.powerWritable !== false;
  if (dev.kind.kind === "fan") return dev.kind.powerWritable !== false;
  return false;
}

/**
 * Built-in `QuickAction` pills visible in real modes (`xiaomiCloud` / `homeAssistant`),
 * mirroring macOS `QuickAction` availability rules (`Models.swift` / `HomeStore+Undo.swift`):
 * each action appears whenever at least one online controllable device of its target family
 * exists in the current view/home.
 */
export function availableQuickActions(
  devices: readonly SmartDevice[],
): BuiltInQuickActionDescriptor[] {
  const hasControllableLight = devices.some(supportsLightsOff);
  const hasNightLightCandidate = devices.some(supportsSoftNightLight);
  const hasControllableClimateOrFan = devices.some(supportsClimateSleepOff);

  const out: BuiltInQuickActionDescriptor[] = [];
  if (hasControllableLight) {
    out.push({
      id: "lightsOff",
      title: quickActionTitle("lightsOff"),
      tint: "amber",
      command: `${QUICK_ACTION_PREFIX}lightsOff`,
    });
  }
  if (hasNightLightCandidate) {
    out.push({
      id: "softNightLight",
      title: quickActionTitle("softNightLight"),
      tint: "indigo",
      command: `${QUICK_ACTION_PREFIX}softNightLight`,
    });
  }
  if (hasControllableClimateOrFan) {
    out.push({
      id: "climateSleepOff",
      title: quickActionTitle("climateSleepOff"),
      tint: "cyan",
      command: `${QUICK_ACTION_PREFIX}climateSleepOff`,
    });
  }
  return out;
}

export interface PlannedQuickActionTarget {
  readonly deviceId: string;
  readonly commands: readonly DeviceCommand[];
  readonly restoreCommands: readonly DeviceCommand[];
  readonly previousKind: SmartDevice["kind"];
  readonly habitIntents: readonly DeviceIntent[];
}

export interface PlannedQuickAction {
  readonly id: QuickActionId;
  readonly title: string;
  readonly targets: readonly PlannedQuickActionTarget[];
  readonly nextLastManuallyUsedLightId: string | null;
}

/**
 * Plans a built-in `QuickAction` with bidirectional undo snapshots (`CODING_STANDARDS.md` §2,
 * `HomeStore+Undo.swift:133-244`). When `softNightLight` turns a previously-off light on,
 * its undo sends `setLightPower(false)` and restores the pre-action `SmartDevice["kind"]`.
 */
export function planQuickAction(
  action: QuickActionId,
  devices: readonly SmartDevice[],
  lastManuallyUsedLightId: string | null = null,
): PlannedQuickAction {
  const title = quickActionTitle(action);
  const targets: PlannedQuickActionTarget[] = [];
  let nextLastLightId = lastManuallyUsedLightId;

  switch (action) {
    case "lightsOff": {
      for (const dev of devices) {
        if (!supportsLightsOff(dev) || dev.kind.kind !== "light") continue;
        const s = dev.kind;
        if (!s.isOn) continue;
        targets.push({
          deviceId: dev.id,
          commands: [{ kind: "setLightPower", entityId: s.entityId, isOn: false }],
          restoreCommands: [{ kind: "setLightPower", entityId: s.entityId, isOn: true }],
          previousKind: structuredClone(dev.kind),
          habitIntents: [{ targetId: dev.id, operation: { kind: "power", isOn: false } }],
        });
      }
      break;
    }

    case "softNightLight": {
      let chosen = devices.filter(
        (dev) => supportsSoftNightLight(dev) && dev.kind.kind === "light" && dev.kind.isOn,
      );
      if (chosen.length === 0) {
        const preferred =
          (lastManuallyUsedLightId
            ? devices.find((dev) => dev.id === lastManuallyUsedLightId && supportsSoftNightLight(dev))
            : undefined) ?? devices.find(supportsSoftNightLight);
        if (preferred) {
          chosen = [preferred];
          if (lastManuallyUsedLightId === null) {
            nextLastLightId = preferred.id;
          }
        }
      }

      for (const dev of chosen) {
        if (dev.kind.kind !== "light") continue;
        const s = dev.kind;
        const targetKelvin =
          s.maxKelvin >= s.minKelvin
            ? Math.min(s.maxKelvin, Math.max(s.minKelvin, 2700))
            : Math.max(s.minKelvin, 2700);
        const prevBri = s.brightnessPercent ?? 80;
        const prevKelvin = s.colorTempKelvin ?? 4000;
        const restoreCommands: DeviceCommand[] = s.isOn
          ? [
              { kind: "setLightBrightness", entityId: s.entityId, percent: prevBri },
              { kind: "setLightColorTemp", entityId: s.entityId, kelvin: prevKelvin },
              ...(s.currentEffect !== null
                ? [{ kind: "setLightEffect" as const, entityId: s.entityId, effect: s.currentEffect }]
                : []),
            ]
          : [{ kind: "setLightPower", entityId: s.entityId, isOn: false }];

        targets.push({
          deviceId: dev.id,
          commands: [
            { kind: "setLightBrightness", entityId: s.entityId, percent: 15 },
            { kind: "setLightColorTemp", entityId: s.entityId, kelvin: targetKelvin },
          ],
          restoreCommands,
          previousKind: structuredClone(dev.kind),
          habitIntents: [
            { targetId: dev.id, operation: { kind: "brightness", percent: 15 } },
            { targetId: dev.id, operation: { kind: "colorTemperature", kelvin: targetKelvin } },
          ],
        });
      }
      break;
    }

    case "climateSleepOff": {
      for (const dev of devices) {
        if (!supportsClimateSleepOff(dev)) continue;
        if (dev.kind.kind === "climate") {
          const s = dev.kind;
          if (!s.isOn || s.hvacMode === "off") continue;
          const prevMode = s.hvacMode;
          targets.push({
            deviceId: dev.id,
            commands: [{ kind: "setClimatePower", entityId: s.entityId, isOn: false, resumeMode: prevMode }],
            restoreCommands: [{ kind: "setClimatePower", entityId: s.entityId, isOn: true, resumeMode: prevMode }],
            previousKind: structuredClone(dev.kind),
            habitIntents: [{ targetId: dev.id, operation: { kind: "power", isOn: false } }],
          });
        } else if (dev.kind.kind === "fan") {
          const s = dev.kind;
          if (!s.isOn) continue;
          targets.push({
            deviceId: dev.id,
            commands: [{ kind: "setFanPower", entityId: s.entityId, isOn: false }],
            restoreCommands: [{ kind: "setFanPower", entityId: s.entityId, isOn: true }],
            previousKind: structuredClone(dev.kind),
            habitIntents: [{ targetId: dev.id, operation: { kind: "power", isOn: false } }],
          });
        }
      }
      break;
    }
  }

  return {
    id: action,
    title,
    targets,
    nextLastManuallyUsedLightId: nextLastLightId,
  };
}
