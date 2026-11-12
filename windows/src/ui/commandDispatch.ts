import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { HomeAssistantClient, homeAssistantCommand } from "../core/homeAssistant.js";
import { MiCloudClient, MiCloudError, MiotCommandMapper, propKeyString } from "../core/miCloudClient.js";
import { readMiotPower, type DeviceCommand, type DeviceKind, type FacetControl, type SmartDevice } from "../core/models.js";
import { applyCommandToDevices } from "../core/commandEffects.js";
import {
  applyHAExtendedCommandEffect,
  claimDeviceWrite,
  COVER_OPTIMISTIC_LOCK_DURATION_MS,
  lockOptimistic,
  OPTIMISTIC_LOCK_DURATION_MS,
  ownsDeviceWrite,
  READ_BACK_DELAY_MS,
  restoreOptimisticLock,
  scheduleDelayedReadBack,
  snapshotOptimisticLock,
  syncDirectCommandToFacets,
  type DeviceWriteClaim,
  type OptimisticLockSnapshot,
} from "../core/optimisticLock.js";

function withReadPower(command: DeviceCommand, isOn: boolean): DeviceCommand {
  switch (command.kind) {
    case "setLightPower":
    case "setClimatePower":
    case "setFanPower":
    case "setSwitch":
      return { ...command, isOn };
    default:
      return command;
  }
}

/**
 * A cover command shown before its send. A cover is write-only — macOS locks it before the send so
 * a pre-command parked snapshot cannot drop the commanded travel (`HomeStore+Controls.swift:
 * togglePrimary`), and again after success, which bumps the revision.
 */
interface CoverOptimisticWrite {
  readonly deviceId: string;
  /** The position the motor started from; a snapshot parked there is pre-command, not confirmation. */
  readonly originPosition: number | null;
  readonly priorDevice: SmartDevice;
  readonly priorFacets: readonly FacetControl[] | undefined;
  readonly priorLock: OptimisticLockSnapshot | null;
}

/** The cover card a motor (`setSelectOption`) or position (`setNumberValue`) command addresses. */
export function coverDeviceForCommand(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): SmartDevice | null {
  if (command.kind !== "setSelectOption" && command.kind !== "setNumberValue") return null;
  const device = host.devices.find(
    (item) => item.kind.kind === "cover" && item.kind.entityId === command.entityId,
  );
  return device ?? null;
}

/**
 * Copies `source.kind` back onto `target.kind` without replacing the device object, so a view or a
 * caller still holding that row sees the restored values.
 */
function restoreKindInPlace(target: SmartDevice, source: SmartDevice): void {
  const kind = target.kind as unknown as Record<string, unknown>;
  const from = source.kind as unknown as Record<string, unknown>;
  for (const key of Object.keys(kind)) {
    if (!(key in from)) delete kind[key];
  }
  for (const [key, value] of Object.entries(from)) {
    kind[key] = typeof value === "object" && value !== null ? structuredClone(value) : value;
  }
}

/**
 * Shows a cover command before it goes out and locks the row for the length of its travel. The
 * previous row, facets and lock are kept so a refused send can put them back.
 */
function beginCoverOptimisticWrite(
  host: MenuMijiaWindowsApp,
  command: DeviceCommand,
): CoverOptimisticWrite | null {
  const device = coverDeviceForCommand(host, command);
  if (!device) return null;
  const facets = host.deviceFacets ?? {};
  const priorDevice = structuredClone(device);
  const priorFacets = facets[device.id] ? structuredClone(facets[device.id]!) : undefined;
  const priorLock = snapshotOptimisticLock(host, device.id);
  const originPosition = device.kind.kind === "cover" ? device.kind.positionPercent : null;
  applyCommandToDevices(host.devices, command, host.settings.connectionMode, facets);
  lockOptimistic(host, device.id, COVER_OPTIMISTIC_LOCK_DURATION_MS, {
    coverOriginPosition: originPosition,
    baselineDevice: priorDevice,
    baselineFacets: priorFacets,
  });
  return { deviceId: device.id, originPosition, priorDevice, priorFacets, priorLock };
}

/** Puts back a refused cover send: the row it displaced, and the lock it displaced. */
function revertCoverOptimisticWrite(host: MenuMijiaWindowsApp, write: CoverOptimisticWrite): void {
  const device = host.devices.find((item) => item.id === write.deviceId);
  if (device) restoreKindInPlace(device, write.priorDevice);
  restoreOptimisticLock(host, write.deviceId, write.priorLock);
}

/** True when no newer command has taken the row this command addresses. */
function stillOwnsWrite(host: MenuMijiaWindowsApp, claim: DeviceWriteClaim | null): boolean {
  return claim === null || ownsDeviceWrite(host, claim);
}

export async function applyCommand(host: MenuMijiaWindowsApp, command: DeviceCommand, readBackPower = false): Promise<boolean> {
    const sourceRevision = host.sourceRevision;
    const originalCommand = command;
    // Claim the row before the request goes out: a later command that takes the same row makes this
    // answer stale, so a slow reply must not overwrite the newer write (`§14`).
    const targetDeviceId = deviceOwningEntityId(
      host.devices,
      host.deviceFacets ?? {},
      command.entityId,
    );
    const claim = targetDeviceId !== null ? claimDeviceWrite(host, targetDeviceId) : null;
    const coverWrite = beginCoverOptimisticWrite(host, command);
    try {
      if (host.settings.connectionMode === "homeAssistant") {
        command = homeAssistantCommand(command, host.devices, host.deviceFacets);
      }
      const readPower = await dispatchCloudCommand(host, command, readBackPower);
      if (typeof readPower === "boolean") command = withReadPower(command, readPower);
    } catch (error) {
      if (sourceRevision !== host.sourceRevision) return false;
      // Only the cover was shown ahead of its send, so only the cover has a row to put back.
      if (coverWrite && stillOwnsWrite(host, claim)) revertCoverOptimisticWrite(host, coverWrite);
      // A command refused for a dead login is the same evidence a refresh gets: the footer must
      // stay offline after the banner is dismissed, so record it before rendering.
      if (error instanceof MiCloudError && error.kind === "sessionExpired") host.miSessionExpired = true;
      host.replyBanner = {
        text: error instanceof Error ? error.message : String(error),
        source: t("控制失败"),
        isError: true,
      };
      host.render();
      return false;
    }
    if (sourceRevision !== host.sourceRevision) return false;
    // A newer command owns this row now; its own optimistic state and lock are the ones to keep.
    if (!stillOwnsWrite(host, claim)) return true;
    const facets = host.deviceFacets ?? {};
    const beforeById = new Map(
      host.devices.map((dev) => [
        dev.id,
        {
          snapshot: JSON.stringify([dev.kind, facets[dev.id] ?? null]),
          coverOrigin: dev.kind.kind === "cover" ? dev.kind.positionPercent : null,
          baselineDevice: structuredClone(dev),
          baselineFacets: facets[dev.id] ? structuredClone(facets[dev.id]) : undefined,
        },
      ]),
    );
    // The cover was already shown and locked before its send, so its baseline is the pre-write row
    // and its travel origin is the position the motor started from.
    if (coverWrite) {
      beforeById.set(coverWrite.deviceId, {
        snapshot: JSON.stringify([coverWrite.priorDevice.kind, coverWrite.priorFacets ?? null]),
        coverOrigin: coverWrite.originPosition,
        baselineDevice: structuredClone(coverWrite.priorDevice),
        baselineFacets: coverWrite.priorFacets
          ? structuredClone(coverWrite.priorFacets)
          : undefined,
      });
    }
    host.localControlRevision += 1;
    // The cover has been showing its commanded travel since before the send, so re-apply the
    // command from the row it started on: applying it to the already-moved row would read as
    // "no change" and report the motor as stopped.
    if (coverWrite) {
      const device = host.devices.find((item) => item.id === coverWrite.deviceId);
      if (device) restoreKindInPlace(device, coverWrite.priorDevice);
    }
    const cameraChanges = applyCommandToDevices(
      host.devices,
      command,
      host.settings.connectionMode,
      facets,
    );
    if (originalCommand.kind === "setMiotProperty" && originalCommand !== command) {
      applyCommandToDevices(
        host.devices,
        originalCommand,
        host.settings.connectionMode,
        facets,
      );
    }
    if (host.settings.connectionMode === "homeAssistant") {
      applyHAExtendedCommandEffect(host.devices, command);
    }
    syncDirectCommandToFacets(facets, command, host.devices);

    for (const change of cameraChanges) {
      if (host.cameraLive.activeLiveCameraId !== change.deviceId || host.cameraLive.liveCameraHidden) continue;
      if (change.isOn) {
        host.cameraLive.reconnectCameraLiveView();
      } else {
        host.cameraLive.stopLiveTransport();
        host.cameraLive.liveCameraLoading = false;
      }
    }

    const modifiedIds = new Set<string>();
    for (const dev of host.devices) {
      const prior = beforeById.get(dev.id);
      const after = JSON.stringify([dev.kind, facets[dev.id] ?? null]);
      if (prior && after !== prior.snapshot) {
        modifiedIds.add(dev.id);
        lockOptimistic(
          host,
          dev.id,
          dev.kind.kind === "cover" ? COVER_OPTIMISTIC_LOCK_DURATION_MS : OPTIMISTIC_LOCK_DURATION_MS,
          {
            coverOriginPosition: prior.coverOrigin,
            baselineDevice: prior.baselineDevice,
            baselineFacets: prior.baselineFacets,
          },
        );
        scheduleDelayedReadBack(host, dev.id, READ_BACK_DELAY_MS);
      }
    }
    // A momentary trigger shows nothing to compare, so the card is still the one that must be
    // re-read: an appliance action (`pressButton`) or a standalone Home Assistant button.
    const isMomentaryTrigger =
      command.kind === "pressButton" ||
      (command.kind === "setSwitch" && command.entityId.startsWith("button."));
    if (modifiedIds.size === 0 && isMomentaryTrigger) {
      const baseEntityId = command.entityId.split("#")[0] ?? command.entityId;
      const ownerId = deviceOwningEntityId(host.devices, facets, baseEntityId);
      if (ownerId) {
        scheduleDelayedReadBack(host, ownerId, READ_BACK_DELAY_MS);
      }
    }

    return true;
  }

/**
 * The card that owns a MIoT entity id, or null when none does. A card's own controls and every
 * 更多设置 row count: a plug's auxiliary control lives on a sibling service (#5), so the drawer
 * address must resolve to the card even though the card's main switch has another one.
 */
export function deviceOwningEntityId(
  devices: readonly SmartDevice[],
  facets: Readonly<Record<string, readonly FacetControl[]>>,
  entityId: string,
): string | null {
  const owner = devices.find((device) => {
    if (kindOwnsEntity(device.kind, entityId)) return true;
    return (facets[device.id] ?? []).some((facet) => facet.target?.entityId === entityId);
  });
  return owner?.id ?? null;
}

/** The entity ids a card's own controls address, before 更多设置 rows are considered. */
function kindOwnsEntity(kind: DeviceKind, entityId: string): boolean {
  switch (kind.kind) {
    case "plug":
      return kind.switchEntityId === entityId || kind.childLockEntityId === entityId;
    case "camera":
      return kind.entityId === entityId || kind.motionDetectionEntityId === entityId;
    case "fridge":
      return (
        kind.modeEntityId === entityId ||
        kind.fridgeTargetEntityId === entityId ||
        kind.freezerTargetEntityId === entityId
      );
    case "speaker":
      return [kind.mediaEntityId, kind.muteSwitchEntityId, kind.sleepModeEntityId].includes(entityId);
    case "appliance":
      // An appliance card addresses several services: main function, power, mode, temperature,
      // light, fan speed and the no-argument actions (#300, #3, #4).
      return [
        kind.entityId,
        kind.powerEntityId,
        kind.modeEntityId,
        kind.temperatureEntityId,
        kind.light?.entityId,
        kind.fanLevel?.entityId,
        kind.startAction?.entityId,
        kind.pauseAction?.entityId,
        kind.stopAction?.entityId,
      ].includes(entityId);
    case "generic":
      // A generic card has no primary service; its switch and 更多设置 rows own the addresses (#6).
      return kind.powerControl?.target?.entityId === entityId;
    case "sensor":
      return false;
    default:
      return kind.entityId === entityId;
  }
}

export async function dispatchCloudCommand(host: MenuMijiaWindowsApp, command: DeviceCommand, readBackPower = false): Promise<boolean | null> {
    const sourceRevision = host.sourceRevision;
    if (host.settings.connectionMode === "demo") return null;
    if (host.settings.connectionMode === "homeAssistant") {
      const client = new HomeAssistantClient(host.settings.haBaseURL, host.settings.haToken);
      await host.endpointSubmission;
      if (sourceRevision !== host.sourceRevision) throw new Error("Connection source changed");
      await client.execute(command);
      return null;
    }
    if (!host.settings.miSession) throw new Error(t("请先扫码登录米家"));
    const session = host.settings.miSession;
    const deviceId = deviceOwningEntityId(host.devices, host.deviceFacets, command.entityId);
    const dev = host.devices.find((d) => d.id === deviceId);
    if (!dev) throw new Error(t("无法找到指令对应的设备"));

    const spec = await host.specResolver.resolve({
      did: dev.id,
      name: dev.name,
      model: dev.model,
      isOnline: dev.isOnline,
      specType: null,
    });
    const mapped = MiotCommandMapper.map(command, spec);
    if (sourceRevision !== host.sourceRevision) throw new Error("Connection source changed");
    const client = new MiCloudClient(session, host.transport);
    if (mapped.kind === "setProps") {
      await client.setProps(mapped.writes);
      if (readBackPower) {
        const power = mapped.writes.find((write) => typeof write.value === "boolean");
        if (power) {
          let read: Map<string, unknown>;
          try {
            read = await client.getProps([power]);
          } catch (error) {
            if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
            throw error;
          }
          const value = read.get(propKeyString(power));
          const isOn = readMiotPower(value);
          if (isOn === null) {
            // The write may have landed; the old row is no longer a trusted reading.
            if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
            throw new Error(t("未能读回设备状态"));
          }
          return isOn;
        }
      }
    } else {
      await client.action(mapped.call);
    }
    return null;
  }

export function markCloudValuesStale(host: MenuMijiaWindowsApp): void {
    if (host.settings.connectionMode === "xiaomiCloud" && host.devices.length > 0) {
      host.cloudValuesStale = true;
    }
  }

export function markCloudValuesFresh(host: MenuMijiaWindowsApp): void {
    if (host.settings.connectionMode === "xiaomiCloud") host.cloudValuesStale = false;
  }
