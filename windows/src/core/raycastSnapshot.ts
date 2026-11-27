import { pinyin } from "pinyin-pro";
import { ManualControlPolicy, isSwitchedLightDevice } from "./assistant.js";
import type { AutomationRunEntry } from "./automationRun.js";
import {
  allOffTargets,
  deviceCanTogglePower,
  deviceStatusSummary,
  isActiveDevice,
  isDeviceActiveOn,
  type EnvironmentReading,
  type HomeScene,
  type RoomCategory,
  type SmartDevice,
} from "./models.js";
import { t } from "./i18n.js";
import { normalizeSearch } from "./panelSearch.js";
import { quickActionTitle } from "./quickActions.js";
import { tr3 } from "./safetyAndHealth.js";
import { formatTemperature } from "./temperature.js";

export const SNAPSHOT_SCHEMA_VERSION = 1;

export interface RaycastCommandFeedback {
  readonly requestId?: string;
  readonly command: string;
  readonly message: string;
  readonly isError: boolean;
  readonly completedAt: string;
}

export interface RaycastDeviceCapabilities {
  readonly canTogglePower: boolean;
  readonly brightnessWritable: boolean;
  readonly brightnessPercent?: number;
  readonly colorWritable: boolean;
  readonly colorTempKelvin?: number;
  readonly minKelvin?: number;
  readonly maxKelvin?: number;
  readonly supportsMoonlight: boolean;
  readonly availableEffects: string[];
  readonly temperatureWritable: boolean;
  readonly targetTemperature?: number;
  readonly currentTemperature?: number;
  readonly minTemp?: number;
  readonly maxTemp?: number;
  readonly step?: number;
  readonly hvacMode?: string;
  readonly availableModes: string[];
  readonly fanSpeedWritable: boolean;
  readonly fanPercentage?: number;
  readonly availablePresetModes: string[];
  readonly coverSubtype?: string;
  readonly positionWritable: boolean;
  readonly positionPercent?: number;
  readonly canMoveCover: boolean;
  readonly volumeWritable?: boolean;
  readonly volumePercent?: number;
  readonly muteWritable?: boolean;
  readonly isMuted?: boolean;
  readonly canPlayPause?: boolean;
  readonly isHighRisk: boolean;
}

export interface RaycastDeviceItem {
  readonly id: string;
  readonly name: string;
  readonly roomId: string;
  readonly roomName: string;
  readonly roomSortOrder: number;
  readonly category: string;
  readonly categoryTitle: string;
  readonly model: string;
  readonly stateText: string;
  readonly isOnline: boolean;
  readonly isActiveOn: boolean;
  readonly isPrimaryToggleable: boolean;
  readonly isFavorite: boolean;
  readonly favoriteRank?: number;
  readonly pinyinInitials: string;
  readonly pinyinFull: string;
  readonly roomPinyinInitials: string;
  readonly capabilities: RaycastDeviceCapabilities;
}

export interface RaycastQuickActionItem {
  readonly id: string;
  readonly name: string;
  readonly subtitle: string;
  readonly icon: string;
  readonly isEnabled: boolean;
  readonly affectedCount: number;
  readonly pinyinInitials: string;
}

export interface RaycastSceneItem {
  readonly id: string;
  readonly name: string;
  readonly entityId: string;
  readonly roomName?: string;
  readonly icon: string;
  readonly visualCategory: string;
  readonly pinyinInitials: string;
  readonly pinyinFull: string;
}

export interface RaycastEnvironmentReadingItem {
  readonly id: string;
  readonly label: string;
  readonly roomName: string;
  readonly temperature?: number;
  readonly humidity?: number;
  readonly battery?: number;
  readonly updatedAt: string;
  readonly pinyinInitials: string;
}

export interface RaycastAutomationRunItem { readonly ruleId: string; readonly trigger: string; readonly result: "executed" | "skipped"; readonly skipReason?: string; readonly at: string; }
export interface RaycastAutomationStatus { readonly enabled: boolean; readonly ruleCount: number; readonly enabledRuleCount: number; readonly executedCount: number; readonly skippedCount: number; readonly recentRuns: RaycastAutomationRunItem[]; }

export interface RaycastSnapshot {
  readonly schemaVersion: number;
  readonly generatedAt: string;
  readonly updatedAt: string;
  readonly connectionMode: string;
  readonly selectedHomeId: string | null;
  readonly bridgeToken: string;
  readonly connectionSummary: string;
  readonly isStale: boolean;
  readonly devices: RaycastDeviceItem[];
  readonly quickActions: RaycastQuickActionItem[];
  readonly scenes: RaycastSceneItem[];
  readonly climate: RaycastEnvironmentReadingItem[];
  readonly environmentReadings: RaycastEnvironmentReadingItem[];
  readonly lastCommandFeedback?: RaycastCommandFeedback;
  readonly automationStatus?: RaycastAutomationStatus;
}

export interface BuildRaycastSnapshotInput {
  readonly now?: Date;
  readonly connectionMode: string;
  readonly selectedHomeId: string | null;
  readonly connectionSummary: string;
  readonly bridgeToken: string;
  readonly isStale: boolean;
  readonly devices: readonly SmartDevice[];
  readonly rooms: readonly RoomCategory[];
  readonly scenes: readonly HomeScene[];
  readonly environmentReadings: readonly EnvironmentReading[];
  readonly favoriteIds?: readonly string[];
  readonly hiddenIds?: readonly string[];
  readonly hideOfflineDevices?: boolean;
  readonly hideGroupedLights?: boolean;
  /** Maps member light `did` -> owning light group `did` (`RaycastSnapshot.swift` `lightGroupOwners`). */
  readonly lightGroupOwners?: ReadonlyMap<string, string> | Readonly<Record<string, string>>;
  /** Alias matching `MenuMijiaWindowsApp.groupOwnerByMemberDid` (`memberDid -> groupDid`). */
  readonly groupOwnerByMemberDid?: ReadonlyMap<string, string>;
  /** Optional group `did` -> member `did[]` map; converted to `member -> group` if provided. */
  readonly lightGroupMembers?:
    | ReadonlyMap<string, readonly string[]>
    | Readonly<Record<string, readonly string[]>>;
  readonly aliases?: Readonly<Record<string, string>>;
  readonly roomAliases?: Readonly<Record<string, string>>;
  readonly roomOrder?: readonly string[];
  readonly allOffOverrides?: Readonly<Record<string, boolean>>;
  readonly undoSummary?: { readonly title: string; readonly count: number } | null;
  readonly lastCommandFeedback?: RaycastCommandFeedback;
  readonly automationStatus?: RaycastAutomationStatus;
}

/** Sanitized automation summary (controlled trigger/skip enums only; no titles, SSIDs, or credentials). */
export function buildSanitizedAutomationStatus(input: {
  readonly enabled: boolean; readonly rules: readonly { readonly isEnabled: boolean }[]; readonly history: readonly AutomationRunEntry[];
}): RaycastAutomationStatus {
  const executedCount = input.history.filter((e) => e.result === "executed").length;
  return {
    enabled: input.enabled, ruleCount: input.rules.length,
    enabledRuleCount: input.rules.filter((r) => r.isEnabled).length,
    executedCount, skippedCount: input.history.length - executedCount,
    recentRuns: input.history.slice(0, 15).map((e) => ({
      ruleId: e.ruleId, trigger: e.trigger, result: e.result,
      ...(e.result === "skipped" ? { skipReason: e.reason } : {}), at: new Date(e.time).toISOString(),
    })),
  };
}

/**
 * Holds one CSPRNG 32-byte hex `bridgeToken` in memory while `enableRaycastIntegration` is on,
 * and revokes/rotates it immediately when the toggle is turned off (ADR-0013, Coding Standard #3).
 */
export class RaycastBridgeTokenManager {
  private activeToken: string | null = null;

  public get active(): string | undefined {
    return this.activeToken ?? undefined;
  }

  public getOrCreate(enabled: boolean): string | undefined {
    if (!enabled) {
      this.activeToken = null;
      return undefined;
    }
    if (!this.activeToken) {
      this.activeToken = generateRandomHexToken();
    }
    return this.activeToken;
  }

  public revoke(): void {
    this.activeToken = null;
  }
}

/**
 * Issues a 32-byte hex bridge token from a cryptographically secure source only.
 *
 * `Math.random()` is deliberately absent: the token is the whole authorization for
 * `menumijia://` control, so a predictable value would let any page drive the user's devices.
 * A build without a CSPRNG must refuse to mint a token instead of degrading to a weak one.
 */
export function generateRandomHexToken(): string {
  const webCrypto = globalThis.crypto;
  if (typeof webCrypto?.getRandomValues !== "function") {
    throw new Error(tr3(
      "安全随机数源不可用，无法生成 Raycast 桥接令牌",
      "安全隨機數源不可用，無法產生 Raycast 橋接權杖",
      "No secure random source is available; refusing to mint a Raycast bridge token",
    ));
  }
  const bytes = new Uint8Array(32);
  webCrypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function pinyinPair(raw: string): { initials: string; full: string } {
  const trimmed = raw.trim();
  if (!trimmed) return { initials: "", full: "" };
  const full = normalizeSearch(pinyin(trimmed, { toneType: "none" }));
  const initials = normalizeSearch(
    trimmed.replace(/\p{Script=Han}+/gu, (han) =>
      pinyin(han, { toneType: "none", pattern: "first", type: "array" }).join(""),
    ),
  );
  return { initials, full };
}

function categoryTitleForDevice(device: SmartDevice): string {
  switch (device.kind.kind) {
    case "light":
      return tr3("照明", "照明", "Lights");
    case "climate":
      return t("空调");
    case "fan":
      return tr3("风扇", "風扇", "Fans");
    case "plug":
      return isSwitchedLightDevice(device)
        ? tr3("照明", "照明", "Lights")
        : t("插座");
    case "fridge":
      return t("冰箱");
    case "vacuum":
      return t("扫地机");
    case "camera":
      return t("摄像机");
    case "sensor":
      return t("传感器");
    case "cover":
      return tr3("窗帘电机", "窗簾電機", "Covers");
    case "speaker":
      return tr3("音箱", "音箱", "Speakers");
    case "tv":
      return t("电视");
    case "humidifier":
      return tr3("加湿器", "加濕器", "Humidifiers");
    case "appliance":
      return tr3("厨卫大家电", "廚衛大家電", "Appliances");
    case "generic":
      return device.kind.typeTitle ? t(device.kind.typeTitle) : tr3("设备", "裝置", "Device");
  }
}

function buildDeviceCapabilities(device: SmartDevice): RaycastDeviceCapabilities {
  const isHighRisk =
    ManualControlPolicy.requiresConfirmation(
      { targetId: device.id, operation: { kind: "power", isOn: true } },
      [device],
    ) ||
    ManualControlPolicy.requiresConfirmation(
      { targetId: device.id, operation: { kind: "power", isOn: false } },
      [device],
    );

  const base: RaycastDeviceCapabilities = {
    canTogglePower: deviceCanTogglePower(device),
    brightnessWritable: false,
    colorWritable: false,
    supportsMoonlight: false,
    availableEffects: [],
    temperatureWritable: false,
    availableModes: [],
    fanSpeedWritable: false,
    availablePresetModes: [],
    positionWritable: false,
    canMoveCover: false,
    isHighRisk,
  };

  const k = device.kind;
  switch (k.kind) {
    case "light":
      return {
        ...base,
        canTogglePower: k.powerWritable !== false,
        brightnessWritable: k.brightnessWritable !== false,
        ...(k.brightnessPercent !== null ? { brightnessPercent: k.brightnessPercent } : {}),
        colorWritable: k.colorWritable !== false,
        ...(k.colorTempKelvin !== null ? { colorTempKelvin: k.colorTempKelvin } : {}),
        minKelvin: k.minKelvin,
        maxKelvin: k.maxKelvin,
        supportsMoonlight:
          k.brightnessWritable !== false || k.colorWritable !== false || k.availableEffects.length > 0,
        availableEffects: [...k.availableEffects],
      };
    case "climate":
      return {
        ...base,
        canTogglePower: k.powerWritable !== false,
        temperatureWritable: k.temperatureWritable !== false,
        targetTemperature: k.targetTemperature,
        ...(k.currentTemperature !== null ? { currentTemperature: k.currentTemperature } : {}),
        minTemp: k.minTemp,
        maxTemp: k.maxTemp,
        step: k.step,
        hvacMode: k.hvacMode,
        availableModes: [...k.availableModes],
      };
    case "fan":
      return {
        ...base,
        canTogglePower: k.powerWritable !== false,
        fanSpeedWritable: k.speedWritable !== false,
        ...(k.percentage !== null ? { fanPercentage: k.percentage } : {}),
        availablePresetModes: [...k.availablePresetModes],
      };
    case "cover":
      return {
        ...base,
        coverSubtype: k.subtype,
        positionWritable: k.positionWritable,
        ...(k.positionPercent !== null ? { positionPercent: k.positionPercent } : {}),
        canMoveCover: k.openDescription !== null && k.closeDescription !== null,
        isHighRisk: isHighRisk || k.subtype === "garage-door" || k.subtype === "window-opener",
      };
    case "speaker":
    case "tv":
      return { ...base, volumeWritable: k.volumeWritable, ...(k.volumePresent !== false ? { volumePercent: k.volumePercent } : {}), muteWritable: Boolean(k.muteSwitchEntityId), isMuted: Boolean(k.isMuted), canPlayPause: k.playback?.canPlayPause === true };
    default:
      return base;
  }
}

function computeRoomRanks(
  rooms: readonly RoomCategory[],
  roomOrder: readonly string[] = [],
): Map<string, number> {
  const customRank = new Map<string, number>();
  roomOrder.forEach((id, idx) => {
    if (!customRank.has(id)) customRank.set(id, idx);
  });
  const ordered = rooms
    .map((room, idx) => ({
      room,
      rank: customRank.get(room.id) ?? roomOrder.length + idx,
    }))
    .sort((a, b) => a.rank - b.rank)
    .map((entry) => entry.room);

  const ranks = new Map<string, number>();
  ordered.forEach((room, idx) => {
    if (!ranks.has(room.id)) ranks.set(room.id, idx);
    if (!ranks.has(room.name)) ranks.set(room.name, idx);
  });
  return ranks;
}

function buildQuickActionItems(
  devices: readonly SmartDevice[],
  allOffOverrides: Readonly<Record<string, boolean>>,
  undoSummary: { readonly title: string; readonly count: number } | null,
): RaycastQuickActionItem[] {
  const activeLightsCount = devices.filter(
    (d) => d.isOnline && d.kind.kind === "light" && d.kind.isOn && d.kind.powerWritable !== false,
  ).length;
  const nightLightCount = devices.filter(
    (d) =>
      d.isOnline &&
      d.kind.kind === "light" &&
      d.kind.brightnessWritable !== false &&
      d.kind.colorWritable !== false,
  ).length;
  const activeClimateFanCount = devices.filter((d) => {
    if (!d.isOnline) return false;
    if (d.kind.kind === "climate") {
      return d.kind.isOn && d.kind.hvacMode !== "off" && d.kind.powerWritable !== false;
    }
    if (d.kind.kind === "fan") {
      return d.kind.isOn && d.kind.powerWritable !== false;
    }
    return false;
  }).length;
  const allOffCount = allOffTargets(devices, allOffOverrides).length;

  const lightsOffTitle = quickActionTitle("lightsOff");
  const softNightTitle = quickActionTitle("softNightLight");
  const climateOffTitle = quickActionTitle("climateSleepOff");
  const allOffTitle = tr3("一键全关", "一鍵全關", "Turn All Off");
  const undoTitle = tr3("撤销上一步", "撤銷上一步", "Undo Last Action");

  return [
    {
      id: "lightsOff",
      name: lightsOffTitle,
      subtitle:
        activeLightsCount > 0
          ? tr3("当前有 {n} 盏灯开启", "目前有 {n} 盞燈開啟", "{n} light(s) currently on", { n: activeLightsCount })
          : tr3("全部灯具已关闭", "全部燈具已關閉", "All lights are already off"),
      icon: "lightbulb.slash",
      isEnabled: activeLightsCount > 0,
      affectedCount: activeLightsCount,
      pinyinInitials: pinyinPair(lightsOffTitle).initials,
    },
    {
      id: "softNightLight",
      name: softNightTitle,
      subtitle:
        nightLightCount > 0
          ? tr3("调至 15% 亮度与 2700K 暖光", "調至 15% 亮度與 2700K 暖光", "Dim to 15% at 2700K warm light")
          : tr3("无支持调光调色温的在线灯具", "無支援調光調色溫的線上燈具", "No dimmable warm-white lights online"),
      icon: "moon.stars",
      isEnabled: nightLightCount > 0,
      affectedCount: nightLightCount > 0 ? 1 : 0,
      pinyinInitials: pinyinPair(softNightTitle).initials,
    },
    {
      id: "climateSleepOff",
      name: climateOffTitle,
      subtitle:
        activeClimateFanCount > 0
          ? tr3("当前有 {n} 台温控/风扇开启", "目前有 {n} 台溫控/風扇開啟", "{n} climate/fan device(s) on", { n: activeClimateFanCount })
          : tr3("空调与风扇均已关闭", "空調與風扇均已關閉", "All climate & fan devices are off"),
      icon: "snowflake.slash",
      isEnabled: activeClimateFanCount > 0,
      affectedCount: activeClimateFanCount,
      pinyinInitials: pinyinPair(climateOffTitle).initials,
    },
    {
      id: "allOff",
      name: allOffTitle,
      subtitle:
        allOffCount > 0
          ? tr3("关闭当前开启的 {n} 台设备（支持撤销）", "關閉目前開啟的 {n} 台裝置（支援撤銷）", "Turn off {n} active device(s) (with undo)", { n: allOffCount })
          : tr3("当前没有开启的设备", "目前沒有開啟的裝置", "No active devices are currently on"),
      icon: "power",
      isEnabled: allOffCount > 0,
      affectedCount: allOffCount,
      pinyinInitials: pinyinPair(allOffTitle).initials,
    },
    {
      id: "undo",
      name: undoTitle,
      subtitle: undoSummary
        ? tr3("可撤销：{title}", "可撤銷：{title}", "Undo: {title}", { title: undoSummary.title })
        : tr3("当前没有可撤销的操作", "目前沒有可撤銷的操作", "Nothing to undo right now"),
      icon: "arrow.uturn.backward",
      isEnabled: Boolean(undoSummary),
      affectedCount: undoSummary?.count ?? 0,
      pinyinInitials: pinyinPair(undoTitle).initials,
    },
  ];
}

function classifyScene(name: string): { icon: string; visualCategory: string } {
  const lower = name.toLowerCase();
  if (/睡|晚安|夜|sleep|night|bed/.test(lower)) {
    return { icon: "moon.stars.fill", visualCategory: "sleep" };
  }
  if (/离家|外出|全关|away|leave|off/.test(lower)) {
    return { icon: "figure.walk.departure", visualCategory: "leave" };
  }
  if (/回家|欢迎|home|arrive/.test(lower)) {
    return { icon: "house.fill", visualCategory: "arrive" };
  }
  if (/影|影院|电视|movie|cinema|tv/.test(lower)) {
    return { icon: "sparkles.tv", visualCategory: "cinema" };
  }
  return { icon: "sparkles", visualCategory: "general" };
}

function normalizeLightGroupOwners(input: BuildRaycastSnapshotInput): Map<string, string> {
  const owners = new Map<string, string>();
  const mergeDirect = (
    source: ReadonlyMap<string, string> | Readonly<Record<string, string>> | undefined,
  ): void => {
    if (!source) return;
    if (source instanceof Map || typeof (source as ReadonlyMap<string, string>).entries === "function") {
      for (const [memberDid, groupDid] of (source as ReadonlyMap<string, string>).entries()) {
        if (memberDid && groupDid && !owners.has(memberDid)) {
          owners.set(memberDid, groupDid);
        }
      }
      return;
    }
    for (const [memberDid, groupDid] of Object.entries(source as Readonly<Record<string, string>>)) {
      if (memberDid && groupDid && !owners.has(memberDid)) {
        owners.set(memberDid, groupDid);
      }
    }
  };
  mergeDirect(input.lightGroupOwners);
  mergeDirect(input.groupOwnerByMemberDid);

  const byGroup = input.lightGroupMembers;
  if (byGroup) {
    if (byGroup instanceof Map || typeof (byGroup as ReadonlyMap<string, readonly string[]>).entries === "function") {
      for (const [groupDid, memberDids] of (byGroup as ReadonlyMap<string, readonly string[]>).entries()) {
        if (!groupDid || !Array.isArray(memberDids)) continue;
        for (const memberDid of memberDids) {
          if (memberDid && !owners.has(memberDid)) {
            owners.set(memberDid, groupDid);
          }
        }
      }
    } else {
      for (const [groupDid, memberDids] of Object.entries(
        byGroup as Readonly<Record<string, readonly string[]>>,
      )) {
        if (!groupDid || !Array.isArray(memberDids)) continue;
        for (const memberDid of memberDids) {
          if (memberDid && !owners.has(memberDid)) {
            owners.set(memberDid, groupDid);
          }
        }
      }
    }
  }
  return owners;
}

/**
 * Computes the companion-visible device list (`RaycastSnapshot.swift` `raycastVisibleDevices` parity):
 * filters hidden and (when enabled) offline devices first, then when `hideGroupedLights` is active
 * folds member lights whose owning light group is itself visible AND online.
 */
export function resolveRaycastVisibleDevices(input: {
  readonly devices: readonly SmartDevice[];
  readonly hiddenIds?: readonly string[];
  readonly hideOfflineDevices?: boolean;
  readonly hideGroupedLights?: boolean;
  readonly lightGroupOwners?: ReadonlyMap<string, string> | Readonly<Record<string, string>>;
  readonly groupOwnerByMemberDid?: ReadonlyMap<string, string>;
  readonly lightGroupMembers?:
    | ReadonlyMap<string, readonly string[]>
    | Readonly<Record<string, readonly string[]>>;
}): SmartDevice[] {
  const hiddenSet = new Set(input.hiddenIds ?? []);
  const baseVisible = input.devices.filter((dev) => {
    if (hiddenSet.has(dev.id)) return false;
    if (input.hideOfflineDevices && !dev.isOnline) return false;
    return true;
  });
  const shouldFold = input.hideGroupedLights ?? true;
  if (!shouldFold) return baseVisible;

  const owners = normalizeLightGroupOwners(input as BuildRaycastSnapshotInput);
  if (owners.size === 0) return baseVisible;

  const listedById = new Map<string, SmartDevice>();
  for (const dev of baseVisible) {
    if (!listedById.has(dev.id)) listedById.set(dev.id, dev);
  }

  return baseVisible.filter((dev) => {
    const groupDid = owners.get(dev.id);
    if (!groupDid) return true;
    const group = listedById.get(groupDid);
    if (!group || !group.isOnline) return true;
    return false;
  });
}

export function buildRaycastSnapshot(input: BuildRaycastSnapshotInput): RaycastSnapshot {
  const isoNow = (input.now ?? new Date()).toISOString();
  const favoriteOrder = input.favoriteIds ?? [];
  const favoriteRankMap = new Map<string, number>();
  favoriteOrder.forEach((id, idx) => {
    if (!favoriteRankMap.has(id)) favoriteRankMap.set(id, idx);
  });
  const aliases = input.aliases ?? {};
  const roomAliases = input.roomAliases ?? {};
  const roomRanks = computeRoomRanks(input.rooms, input.roomOrder);

  const visible = resolveRaycastVisibleDevices(input);

  const sortedDevices = visible
    .map((dev, index) => ({ dev, index }))
    .sort((lhs, rhs) => {
      const aFav = favoriteRankMap.has(lhs.dev.id);
      const bFav = favoriteRankMap.has(rhs.dev.id);
      if (aFav !== bFav) return aFav ? -1 : 1;
      if (aFav && bFav) {
        const rA = favoriteRankMap.get(lhs.dev.id) ?? Number.MAX_SAFE_INTEGER;
        const rB = favoriteRankMap.get(rhs.dev.id) ?? Number.MAX_SAFE_INTEGER;
        if (rA !== rB) return rA - rB;
      }
      const roomA = roomRanks.get(lhs.dev.roomId) ?? roomRanks.get(lhs.dev.roomName) ?? 999;
      const roomB = roomRanks.get(rhs.dev.roomId) ?? roomRanks.get(rhs.dev.roomName) ?? 999;
      if (roomA !== roomB) return roomA - roomB;
      return lhs.index - rhs.index;
    })
    .map((entry) => entry.dev);

  let favCounter = 0;
  const deviceItems: RaycastDeviceItem[] = sortedDevices.map((dev) => {
    const isFav = favoriteRankMap.has(dev.id);
    const favRank = isFav ? favCounter++ : undefined;
    const displayName = aliases[dev.id]?.trim() || dev.name;
    const effectiveDev = displayName === dev.name ? dev : { ...dev, name: displayName };
    const switchedLight = isSwitchedLightDevice(effectiveDev);
    const displayRoom = roomAliases[dev.roomId]?.trim() || dev.roomName;
    const roomOrder = roomRanks.get(dev.roomId) ?? roomRanks.get(dev.roomName) ?? 999;
    const namePinyin = pinyinPair(displayName);
    const roomPinyin = pinyinPair(displayRoom);

    return {
      id: dev.id,
      name: displayName,
      roomId: dev.roomId,
      roomName: displayRoom,
      roomSortOrder: roomOrder,
      category: switchedLight ? "light" : dev.kind.kind,
      categoryTitle: switchedLight ? tr3("照明", "照明", "Lights") : categoryTitleForDevice(effectiveDev),
      model: dev.model,
      stateText: deviceStatusSummary(dev),
      isOnline: dev.isOnline,
      isActiveOn: isDeviceActiveOn(dev),
      isPrimaryToggleable: deviceCanTogglePower(dev),
      isFavorite: isFav,
      ...(favRank !== undefined ? { favoriteRank: favRank } : {}),
      pinyinInitials: namePinyin.initials,
      pinyinFull: namePinyin.full,
      roomPinyinInitials: roomPinyin.initials,
      capabilities: buildDeviceCapabilities(effectiveDev),
    };
  });

  const quickActions = buildQuickActionItems(
    visible,
    input.allOffOverrides ?? {},
    input.undoSummary ?? null,
  );

  const sceneItems: RaycastSceneItem[] = input.scenes.map((scene) => {
    const p = pinyinPair(scene.name);
    const visual = classifyScene(scene.name);
    return {
      id: scene.id,
      name: scene.name,
      entityId: scene.entityId,
      icon: visual.icon,
      visualCategory: visual.visualCategory,
      pinyinInitials: p.initials,
      pinyinFull: p.full,
    };
  });

  const orderedReadings = input.environmentReadings
    .map((reading, index) => ({ reading, index }))
    .sort((lhs, rhs) => {
      const rankA = roomRanks.get(lhs.reading.roomName) ?? 999;
      const rankB = roomRanks.get(rhs.reading.roomName) ?? 999;
      if (rankA !== rankB) return rankA - rankB;
      return lhs.index - rhs.index;
    })
    .map((entry) => entry.reading);

  const readingItems: RaycastEnvironmentReadingItem[] = orderedReadings.map((reading) => {
    const matchedRoom = input.rooms.find(
      (r) => r.name === reading.roomName || r.id === reading.roomName,
    );
    const roomId = matchedRoom?.id ?? reading.roomName;
    const displayRoom = roomAliases[roomId]?.trim() || reading.roomName;
    const combinedPinyin = pinyinPair(`${displayRoom} ${reading.label}`);
    return {
      id: reading.id,
      label: reading.label,
      roomName: displayRoom,
      ...(reading.temperature !== null ? { temperature: reading.temperature } : {}),
      ...(reading.humidity !== null ? { humidity: reading.humidity } : {}),
      ...(reading.battery !== null ? { battery: reading.battery } : {}),
      updatedAt: isoNow,
      pinyinInitials: combinedPinyin.initials,
    };
  });

  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    generatedAt: isoNow,
    updatedAt: isoNow,
    connectionMode: input.connectionMode,
    selectedHomeId: input.selectedHomeId,
    bridgeToken: input.bridgeToken,
    connectionSummary: input.connectionSummary,
    isStale: input.isStale,
    devices: deviceItems,
    quickActions,
    scenes: sceneItems,
    climate: readingItems,
    environmentReadings: readingItems,
    ...(input.lastCommandFeedback ? { lastCommandFeedback: input.lastCommandFeedback } : {}),
    ...(input.automationStatus ? { automationStatus: input.automationStatus } : {}),
  };
}

/**
 * Formats a concise live summary for the Windows system tray tooltip:
 * primary environment reading (temperature / humidity) + active-on device count.
 */
export function formatDynamicTraySummary(
  readings: readonly EnvironmentReading[],
  devices: readonly SmartDevice[],
): string | null {
  const parts: string[] = [];
  const primary = readings.find((r) => r.temperature !== null || r.humidity !== null);
  if (primary) {
    const envTokens: string[] = [];
    if (primary.temperature !== null) {
      envTokens.push(formatTemperature(primary.temperature, undefined, 1));
    }
    if (primary.humidity !== null) {
      envTokens.push(`${Math.round(primary.humidity)}%`);
    }
    if (envTokens.length > 0) {
      parts.push(envTokens.join(" "));
    }
  }
  if (devices.length > 0) {
    const activeCount = devices.filter((d) => d.isOnline && isActiveDevice(d)).length;
    parts.push(
      activeCount > 0
        ? tr3("{count} 台开启", "{count} 台開啟", "{count} on", { count: activeCount })
        : tr3("全部关闭", "全部關閉", "All off"),
    );
  }
  return parts.length > 0 ? parts.join(" · ") : null;
}
