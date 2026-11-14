import { markTimerSnapshotReady } from "./scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { MiCloudClient, MiCloudError, MiotSynthesizer, normalizeMiCloudRegion, type MiDeviceRecord, type MiRoom, type MiSession, type MiotDeviceSpec, type MiotPropKey } from "../core/miCloudClient.js";
import { discoverMiHome } from "../core/miCloud/discovery.js";
import { HomeAssistantClient, homeAssistantIdentity, type HAInvoke } from "../core/homeAssistant.js";
import { applyOrder, homeOptions, pageSections, scopedKey, spans, tr3, withAliases } from "./panelPrefs.js";
import { filterByListCut, foldGroupedLights, kindChips, memberGroupOwners, showsKindRow } from "./listCut.js";
import { hasMatchingDomShape, morphMatchingDom, parseSingleElement } from "./dom.js";
import { environmentReadingPriority, type HomeBackend, type SmartDevice } from "../core/models.js";
import { appDiagnosticsLog } from "../core/diagnosticsAndScanner.js";
import {
  DUAL_SOURCE_ENABLED_STORAGE_KEY,
  DualSourceCoordinator,
  extractMiDeviceIdentities,
  fetchHASnapshotWithIdentities,
  type DeviceMergeResult,
  type DualSourceInputSnapshot,
} from "../core/dualSourceProvider.js";
import {
  MiAccountsStore,
  hasSecondaryMiAccountsInIndex,
  makeMiAccount,
  refreshMiAccountsConcurrently,
  type AccountChildSnapshot,
  type MergedMiAccountsSnapshot,
  type MiAccount,
} from "../core/miAccountsStore.js";
import { isHostAttachedToActiveWindow, mergeHomeSnapshotRespectingLocks } from "../core/optimisticLock.js";
import { getUnsupportedLightEffects } from "./commandDispatch.js";
import type { HASnapshotLike } from "../core/automationEngine.js";
import { ingestHostHASnapshotForDoorbell, structuralActivityStackKey } from "./activityStackView.js";
import { energyScopeForHost, plugTodaySummaryForDrawer, syncEnergyHostOnRender } from "./energySettingsView.js";
import { structuralSensorHistoryKey, syncSensorHistoryHost } from "./sensorHistoryView.js";
import { availableQuickActions } from "../core/quickActions.js";
import { renderSliderDeck } from "./panelView.js";
import { isWorkstationLocked } from "./transport.js";
import {
  clearCachedXiaomiTopology,
  clearPersistedMiSessionExpired,
  clearXiaomiRateLimitBackoff,
  isPersistedMiSessionExpired,
  isXiaomiRateLimitError,
  miSessionFingerprint,
  persistMiSessionExpired,
  recordXiaomiRateLimit,
  shouldSkipSilentPollForBackoff,
  storeCachedXiaomiTopology,
  takeCachedXiaomiTopologyForPoll,
} from "../core/pollingPolicy.js";

export function foldGrouped(host: MenuMijiaWindowsApp, devices: readonly SmartDevice[]): SmartDevice[] {
    return host.settings.hideGroupedLights
      ? foldGroupedLights(devices, host.groupOwnerByMemberDid)
      : [...devices];
  }

function collectMiotPropKeys(
  rawDevices: readonly MiDeviceRecord[],
  specs: Readonly<Record<string, MiotDeviceSpec>>,
): MiotPropKey[] {
  const propKeys: MiotPropKey[] = [];
  const propKeySeen = new Set<string>();
  const addPropKeys = (keys: readonly MiotPropKey[]) => {
    for (const key of keys) {
      const id = `${key.did}.${key.siid}.${key.piid}`;
      if (propKeySeen.has(id)) continue;
      propKeySeen.add(id);
      propKeys.push(key);
    }
  };
  for (const dev of rawDevices) {
    const spec = specs[dev.model];
    if (spec) {
      addPropKeys(MiotSynthesizer.requiredProps(dev, spec));
      addPropKeys(MiotSynthesizer.facetProps(dev, spec));
    }
  }
  return propKeys;
}

export async function refreshDevices(host: MenuMijiaWindowsApp, silent = false): Promise<void> {
    if (!isHostAttachedToActiveWindow(host)) return;
    if (isDualSourceEnabled(host)) return refreshDualSourceDevices(host, silent);
    if (host.settings.connectionMode === "homeAssistant") return refreshHADevices(host, silent);
    if (host.settings.connectionMode === "xiaomiCloud" && hasMultipleMiAccountsForHost(host)) {
      return refreshMultiAccountXiaomiDevices(host, silent);
    }
    if (!host.settings.miSession || host.settings.connectionMode !== "xiaomiCloud" || host.isSyncingCloud) return;
    const session = host.settings.miSession;
    const currentFingerprint = miSessionFingerprint(session);
    const previousFingerprint = host.lastSessionFingerprint ?? undefined;
    host.lastSessionFingerprint = currentFingerprint;
    const isInitialStartupCheck = !host.initialSessionCheckDone;
    host.initialSessionCheckDone = true;
    const expiredBefore = host.miSessionExpired;
    const persistedExpired = isPersistedMiSessionExpired(session);
    if (previousFingerprint !== undefined && previousFingerprint !== currentFingerprint && !persistedExpired) {
      host.miSessionExpired = false;
    } else if (persistedExpired && !host.miSessionExpired) {
      host.miSessionExpired = true;
    }
    if (silent && host.miSessionExpired) {
      if (!expiredBefore && isHostAttachedToActiveWindow(host)) {
        host.queueBackgroundRender();
      }
      return;
    }
    if (!silent && isInitialStartupCheck && !host.isPollingQR && persistedExpired) {
      host.render();
      return;
    }
    const refreshStartedAt = Date.now();
    if (silent && shouldSkipSilentPollForBackoff(host, session, refreshStartedAt)) {
      return;
    }
    if (silent && typeof window !== "undefined" && window.__TAURI_INTERNALS__?.invoke) {
      if (host.lockProbeInFlight) return;
      host.lockProbeInFlight = true;
      let locked = false;
      try {
        locked = await isWorkstationLocked();
      } finally {
        host.lockProbeInFlight = false;
      }
      if (locked) {
        host.lastCloudRefreshAt = null;
        return;
      }
      if (
        !isHostAttachedToActiveWindow(host) ||
        host.settings.connectionMode !== "xiaomiCloud" ||
        host.settings.miSession !== session ||
        host.isSyncingCloud
      ) {
        return;
      }
    }
    const normalizedRegion = normalizeMiCloudRegion(session.region);
    const previousPresentation = cloudPresentationFingerprint(host);
    const previousStructure = cloudPanelStructureFingerprint(host);
    const staleBefore = host.cloudValuesStale;
    const stateRevisionAtStart = host.localControlRevision;
    const selectedHomeAtStart = host.settings.selectedHomeId;
    const sourceRevisionAtStart = host.sourceRevision;
    const syncGen = ++host.syncGeneration;
    let presentationChanged = false;
    host.isSyncingCloud = true;
    host.lastCloudRefreshAt = refreshStartedAt;
    if (!silent) {
      host.render();
    }

    try {
      const client = new MiCloudClient(session, host.transport);
      const cachedTopology = takeCachedXiaomiTopologyForPoll(
        host,
        session,
        sourceRevisionAtStart,
        selectedHomeAtStart ?? null,
        silent,
      );

      let rawDevices: readonly MiDeviceRecord[];
      let rooms: readonly MiRoom[];
      let specs: Readonly<Record<string, MiotDeviceSpec>>;
      let membersByGroup: ReadonlyMap<string, readonly string[]>;
      let allDevicesForCache: readonly MiDeviceRecord[] | null = null;
      let allRoomsForCache: readonly MiRoom[] | null = null;

      if (cachedTopology) {
        rawDevices = cachedTopology.rawDevices;
        rooms = cachedTopology.rooms;
        specs = cachedTopology.specs;
        membersByGroup = cachedTopology.membersByGroup;
      } else {
        const discovery = await discoverMiHome(client, {
          unresolvedDids: host.unresolvedRoomDids,
          retryUnresolved: !silent,
          cachedRooms: () => {
            const cached = host.lastGoodXiaomiRooms;
            return cached &&
              cached.sourceRevision === host.sourceRevision &&
              cached.userId === session.userId &&
              cached.region === normalizedRegion
              ? cached.rooms
              : null;
          },
          onRoomsRead: (fetchedRooms) => {
            host.lastGoodXiaomiRooms = {
              sourceRevision: host.sourceRevision,
              userId: session.userId,
              region: normalizedRegion,
              rooms: fetchedRooms,
            };
          },
        });
        const homeRoomsError = discovery.roomsError;
        const allRooms = discovery.rooms;
        const allDevices = discovery.devices;
        const nextHomes = homeOptions(allRooms);
        if (cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) return;
        if (homeRoomsError === null || nextHomes.length > 0) {
          host.homes = applyOrder(host.homes.map((home) => home.id), nextHomes);
        }
        const filtered = filterBySelectedHome(host, allDevices, allRooms);
        rawDevices = filtered.devices;
        rooms = filtered.rooms;
        allDevicesForCache = allDevices;
        allRoomsForCache = allRooms;
        const groupDids = rawDevices.map((device) => device.did).filter((did) => did.startsWith("group."));
        const membershipPromise = groupDids.length > 0
          ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
          : Promise.resolve(new Map<string, string[]>());

        const stage1Specs = host.specResolver.exportCachedSpecs();
        const stage1Home = MiotSynthesizer.synthesize(
          rawDevices,
          rooms,
          stage1Specs,
          new Map<string, unknown>(),
        );
        if (stage1Home.devices.length > 0 && host.devices.length === 0) {
          host.devices = stage1Home.devices;
          host.deviceFacets = stage1Home.deviceFacets ?? {};
          presentationChanged = true;
          host.render();
        }

        specs = await host.specResolver.resolveForDevices(rawDevices);
        membersByGroup = await membershipPromise;
      }

      // Card properties plus the 更多设置 rows (#5), deduped so one snapshot covers both.
      const propKeys = collectMiotPropKeys(rawDevices, specs);

      let values: Map<string, unknown>;
      try {
        values =
          propKeys.length > 0
            ? await client.getProps(propKeys)
            : new Map<string, unknown>();
      } catch (error) {
        if (!cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) {
          host.markCloudValuesStale();
        }
        throw error;
      }

      const home = MiotSynthesizer.synthesize(rawDevices, rooms, specs, values);
      if (cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) return;
      if (allDevicesForCache !== null && allRoomsForCache !== null) {
        storeCachedXiaomiTopology(host, {
          sessionFingerprint: miSessionFingerprint(session),
          sourceRevision: sourceRevisionAtStart,
          selectedHomeId: selectedHomeAtStart ?? null,
          allDevices: allDevicesForCache,
          allRooms: allRoomsForCache,
          rawDevices,
          rooms,
          specs,
          membersByGroup,
        });
      }
      clearXiaomiRateLimitBackoff(host);
      host.miSessionExpired = false;
      clearPersistedMiSessionExpired();
      host.markCloudValuesFresh();
      host.groupOwnerByMemberDid = memberGroupOwners(membersByGroup as Map<string, string[]>);
      const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
      host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
      host.deviceFacets = merged.deviceFacets;
      if (
        host.cameraLive.activeLiveCameraId !== null &&
        !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
      ) {
        host.cameraLive.closeCameraLiveView();
      }
      const readingPriorityById = new Map(
        home.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      host.environmentReadings = applyOrder(
        host.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      presentationChanged =
        presentationChanged || cloudPresentationFingerprint(host) !== previousPresentation;

      markTimerSnapshotReady(host);
      host.settings.cachedXiaomiDevices = host.devices;
      const knownModelTypes = host.specResolver.exportKnownModelTypes(
        rawDevices.map((d) => d.model),
      );
      const cacheChanged =
        JSON.stringify(knownModelTypes) !== JSON.stringify(host.settings.cachedModelTypes);
      host.settings.cachedModelTypes = knownModelTypes;
      if (presentationChanged || cacheChanged) {
        host.saveSettings();
      }

      if (!silent) {
        host.replyBanner = {
          text:
            home.devices.length > 0
              ? t("已同步 {count} 台真实米家设备", { count: home.devices.length })
              : t("当前小米账号下暂未发现米家设备"),
          source: t("米家云直连"),
        };
      }
    } catch (err) {
      if (!cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) {
        host.markCloudValuesStale();
        appDiagnosticsLog.record({
          error: err,
          category:
            err instanceof MiCloudError && err.kind === "sessionExpired"
              ? "auth"
              : isXiaomiRateLimitError(err)
                ? "rateLimit"
                : "miCloud",
          statusCode: err instanceof MiCloudError ? (err.code ?? null) : null,
          forbiddenLiterals: [session.userId, session.cUserId, session.serviceToken, session.ssecurity],
        });
        if (err instanceof MiCloudError && err.kind === "sessionExpired") {
          host.miSessionExpired = true;
          persistMiSessionExpired(session, true);
          clearCachedXiaomiTopology(host);
        } else if (isXiaomiRateLimitError(err)) {
          recordXiaomiRateLimit(host, session, Date.now());
        }
      }
      if (!silent) {
        const msg = err instanceof Error ? err.message : String(err);
        host.replyBanner = {
          text: t("米家云同步失败：{message}", { message: msg }),
          source: t("连接异常"),
          isError: true,
        };
      }
    } finally {
      if (host.syncGeneration === syncGen) {
        host.isSyncingCloud = false;
        if (isHostAttachedToActiveWindow(host)) {
          const staleChanged = staleBefore !== host.cloudValuesStale;
          const expiredChanged = expiredBefore !== host.miSessionExpired;
          if (!silent) {
            host.render();
          } else if (staleChanged || expiredChanged) {
            host.queueBackgroundRender();
          } else if (presentationChanged) {
            if (
              cloudPanelStructureFingerprint(host) !== previousStructure ||
              !patchCloudPresentation(host)
            ) {
              host.queueBackgroundRender();
            }
          }
        }
      }
    }
  }

export async function refreshHADevices(host: MenuMijiaWindowsApp, silent = false): Promise<void> {
    if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "homeAssistant" || host.isSyncingCloud) return;
    const endpoint = host.settings.haBaseURL;
    const token = host.settings.haToken;
    const revision = host.localControlRevision;
    const syncGen = ++host.syncGeneration;
    const previousPresentation = cloudPresentationFingerprint(host);
    const previousStructure = cloudPanelStructureFingerprint(host);
    let failed = false;
    let shouldUpdateView = false;
    host.isSyncingCloud = true;
    host.lastCloudRefreshAt = Date.now();
    if (!silent && host.devices.length === 0) host.render();
    try {
      await host.endpointSubmission;
      const haClient = new HomeAssistantClient(endpoint, token, host.haInvokeOverride ?? undefined);
      const home = await haClient.snapshot();
      const identity = homeAssistantIdentity(endpoint, token);
      if (!identity) throw new Error("Invalid Home Assistant URL");
      if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "homeAssistant" || host.settings.haBaseURL !== endpoint || host.settings.haToken !== token || host.localControlRevision !== revision || host.syncGeneration !== syncGen) return;
      const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
      host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
      host.deviceFacets = merged.deviceFacets;
      host.scenes = home.scenes;
      if (haClient.lastRawSnapshot && typeof haClient.lastRawSnapshot === "object") {
        void ingestHostHASnapshotForDoorbell(host, haClient.lastRawSnapshot as HASnapshotLike);
      }
      if (
        host.cameraLive.activeLiveCameraId !== null &&
        !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
      ) {
        host.cameraLive.closeCameraLiveView();
      }
      markTimerSnapshotReady(host);
      const readingPriorityById = new Map(
        host.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      host.environmentReadings = applyOrder(
        host.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      const hadValidCache = host.settings.cachedHAHome?.identity === identity;
      const presentationChanged =
        cloudPresentationFingerprint(host) !== previousPresentation || host.haConnectionError !== null;
      const cachedHome = {
        devices: host.devices,
        rooms: home.rooms,
        environmentReadings: host.environmentReadings,
        scenes: home.scenes,
        ...(Object.keys(host.deviceFacets).length > 0 ? { deviceFacets: host.deviceFacets } : {}),
      };
      host.settings.cachedHAHome = { identity, home: cachedHome };
      if (host.haConnectionError !== null) failed = true;
      host.haConnectionError = null;
      if (presentationChanged || !hadValidCache) host.saveSettings();
      shouldUpdateView = !silent || presentationChanged;
    } catch (error) {
      if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "homeAssistant" || host.settings.haBaseURL !== endpoint || host.settings.haToken !== token || host.localControlRevision !== revision || host.syncGeneration !== syncGen) return;
      failed = true;
      shouldUpdateView = true;
      appDiagnosticsLog.record({
        error,
        category: "homeAssistant",
        forbiddenLiterals: [endpoint, token],
      });
      host.haConnectionError = error instanceof Error ? error.message : String(error);
    } finally {
      if (host.syncGeneration === syncGen) {
        host.isSyncingCloud = false;
        if (shouldUpdateView && isHostAttachedToActiveWindow(host)) {
          if (failed || host.devices.length === 0 || cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)) host.queueBackgroundRender();
        }
      }
    }
  }

  export function cloudPresentationFingerprint(host: MenuMijiaWindowsApp): string {
    return JSON.stringify({
      homes: host.homes,
      devices: host.devices,
      deviceFacets: host.deviceFacets,
      scenes: host.scenes,
      environmentReadings: host.environmentReadings,
      groupOwners: [...host.groupOwnerByMemberDid],
    });
  }

export function cloudSnapshotIsStale(
  host: MenuMijiaWindowsApp,
  session: MiSession,
  revision: number,
  syncGen?: number,
  selectedHomeId?: string | null,
): boolean {
    return (
      !isHostAttachedToActiveWindow(host) ||
      host.settings.connectionMode !== "xiaomiCloud" ||
      host.settings.miSession !== session ||
      host.localControlRevision !== revision ||
      (syncGen !== undefined && host.syncGeneration !== syncGen) ||
      (selectedHomeId !== undefined && host.settings.selectedHomeId !== selectedHomeId)
    );
  }

export function cloudPanelStructureFingerprint(host: MenuMijiaWindowsApp): string {
    const kindChipsForPanel = kindChips(
      host.devices,
      host.listCut,
      host.settings.hideOfflineDevices,
      { layout: host.layout },
    );
    const quickActions =
      host.settings.showQuickActionsBar && host.settings.connectionMode !== "demo"
        ? availableQuickActions(foldGrouped(host, filterByListCut(host.devices, host.listCut, false, { layout: host.layout }))).map(
            (action) => action.id,
          )
        : null;
    return JSON.stringify({
      homes: host.homes,
      scenes: host.scenes,
      quickActions,
      kindChips: kindChipsForPanel,
      kindRowVisible: showsKindRow(kindChipsForPanel, host.listCut),
      groupOwners: [...host.groupOwnerByMemberDid],
      sensorHistory: structuralSensorHistoryKey(host),
      activityStack: structuralActivityStackKey(host),
      allOffTargets: host.settings.connectionMode === "homeAssistant" ? null : host.allOffTargets.map((device) => device.id),
      devices: host.devices.map((device) => {
        const kind = device.kind;
        const capabilities =
          kind.kind === "light"
            ? [
                kind.availableEffects,
                [...getUnsupportedLightEffects(host, device.id)],
                kind.minKelvin,
                kind.maxKelvin,
                kind.powerWritable !== false,
                kind.brightnessWritable !== false,
                kind.colorWritable !== false,
              ]
            : kind.kind === "climate"
              ? [kind.availableModes, kind.availableFanModes, kind.minTemp, kind.maxTemp, kind.step]
              : kind.kind === "fan"
                ? [kind.availablePresetModes]
                : kind.kind === "vacuum"
                  ? [kind.availableModes]
                  : kind.kind === "camera"
                    ? [kind.availableNightShots, kind.motionDetectionEntityId]
                    : kind.kind === "cover"
                      ? [
                          kind.subtype,
                          kind.positionWritable,
                          kind.openDescription,
                          kind.closeDescription,
                          kind.pauseDescription,
                        ]
                      : kind.kind === "appliance"
                        ? [
                            kind.powerPresent,
                            kind.powerWritable,
                            kind.availableModes,
                            kind.modeWritable,
                            kind.temperatureWritable,
                            kind.minTemp,
                            kind.maxTemp,
                            kind.step,
                            kind.symbolName,
                            kind.heats,
                          ]
                        : kind.kind === "speaker"
                          ? [
                              kind.volumeWritable,
                              kind.muteSwitchEntityId,
                              kind.sleepModeEntityId,
                              kind.ttsActionId,
                              kind.directiveActionId,
                            ]
                          : kind.kind === "plug"
                            ? (() => {
                                const hasEnergy =
                                  kind.energyKwh !== null &&
                                  kind.energyKwh !== undefined &&
                                  Number.isFinite(kind.energyKwh);
                                const todaySummary = plugTodaySummaryForDrawer(device, hasEnergy, energyScopeForHost(host));
                                return [
                                  hasEnergy,
                                  todaySummary !== null,
                                  todaySummary?.costText !== null,
                                ];
                              })()
                            : [];
        const facetIds = (host.deviceFacets[device.id] ?? []).map((facet) => [
          facet.id,
          facet.kind,
          facet.isWritable,
        ]);
        return {
          id: device.id,
          name: device.name,
          roomId: device.roomId,
          roomName: device.roomName,
          model: device.model,
          category: kind.kind,
          capabilities,
          ...(facetIds.length > 0 ? { facetIds } : {}),
          sensorShape:
            kind.kind === "sensor"
              ? [kind.temperature !== null, kind.humidity !== null, kind.battery !== null]
              : null,
        };
      }),
    });
  }

export function patchCloudPresentation(host: MenuMijiaWindowsApp): boolean {
    if (
      host.isEditingLayout ||
      host.activeSheet !== "none" ||
      host.pointerIsDown ||
      host.draggingId !== null
    ) {
      return false;
    }
    syncSensorHistoryHost(host);
    syncEnergyHostOnRender(host);

    const isAll = host.selectedRoom === "全部";
    const ordered = withAliases(host.layout, applyOrder(host.layout.order, host.presentationDevices));
    const sections = pageSections(host.layout, ordered, isAll);
    const desiredHeaders = sections.filter((section) => section.title !== null);
    const domHeaders = Array.from(host.root.querySelectorAll<HTMLElement>(".cc-group-header"));
    if (domHeaders.length !== desiredHeaders.length) return false;
    for (const section of desiredHeaders) {
      const header = domHeaders.find((element) => element.dataset.collapse === section.id);
      const count = header?.querySelector(".cc-group-count")?.textContent ?? "";
      if (!header || count !== String(section.devices.length)) return false;
    }
    const tilePatches: Array<{ current: HTMLElement; desired: Element }> = [];
    const tileElementsById = new Map<string, HTMLElement>();
    for (const element of host.root.querySelectorAll<HTMLElement>("[data-tile-id]")) {
      const tileId = element.dataset.tileId ?? "";
      if (tileId) tileElementsById.set(tileId, element);
    }
    const unmatchedTileIds = new Set(tileElementsById.keys());
    let index = 0;
    for (const section of sections) {
      const hasActiveSubpage =
        host.expandedDeviceId !== null && section.devices.some((device) => device.id === host.expandedDeviceId);
      if (host.layout.collapsed.includes(scopedKey(host.pageKey, section.id)) && !hasActiveSubpage) continue;
      const spanMap = spans(
        section.devices,
        (device) => (host.expandedDeviceId === device.id ? "full" : host.tileSize(device)),
      );
      for (const device of section.devices) {
        unmatchedTileIds.delete(device.id);
        const current = tileElementsById.get(device.id);
        const desired = parseSingleElement(
          host.renderDeviceTile(device, spanMap.get(device.id) ?? 6, index++),
        );
        if (!current || !desired || !hasMatchingDomShape(current, desired)) return false;
        tilePatches.push({ current, desired });
      }
    }
    if (unmatchedTileIds.size > 0) return false;
    for (const patch of tilePatches) morphMatchingDom(patch.current, patch.desired);
    if (host.settings.connectionMode === "homeAssistant") {
      const current = host.root.querySelector<HTMLElement>("#btn-all-off");
      const desired = parseSingleElement(host.renderAllOffControl());
      if (current && desired) {
        morphMatchingDom(current, desired);
      } else if (current) {
        current.remove();
      } else if (desired) {
        host.root.querySelector(".cc-footer-status")?.append(desired);
        host.bindAllOffControl();
      }
    }

    const envHTML = host.renderEnvironmentStrip();
    const currentEnv = host.root.querySelector<HTMLElement>(".cc-env-strip");
    if (currentEnv) {
      const desiredEnv = parseSingleElement(envHTML);
      if (!desiredEnv) {
        currentEnv.remove();
      } else if (hasMatchingDomShape(currentEnv, desiredEnv)) {
        morphMatchingDom(currentEnv, desiredEnv);
      } else {
        currentEnv.replaceWith(desiredEnv);
      }
    } else if (envHTML) {
      host.root.querySelector(".cc-header-top")?.insertAdjacentHTML("afterend", envHTML);
    }

    if (!host.root.querySelector(".win-slider-deck:focus-within")) {
      const deckHTML = renderSliderDeck(host);
      const currentDeck = host.root.querySelector<HTMLElement>(".win-slider-deck");
      const desiredDeck = parseSingleElement(deckHTML);
      if (currentDeck && !desiredDeck) {
        currentDeck.remove();
      } else if (currentDeck && desiredDeck) {
        if (hasMatchingDomShape(currentDeck, desiredDeck)) {
          morphMatchingDom(currentDeck, desiredDeck);
        } else {
          currentDeck.replaceWith(desiredDeck);
          host.bindDeckEvents();
        }
      } else if (!currentDeck && desiredDeck) {
        host.root.querySelector(".cc-footer")?.before(desiredDeck);
        host.bindDeckEvents();
      }
    }

    const subtitle = host.root.querySelector<HTMLElement>(".cc-subtitle");
    if (subtitle) subtitle.textContent = host.statusSummaryText;
    host.root
      .querySelector<HTMLElement>(".cc-home-badge")
      ?.classList.toggle("is-active", host.activeDeviceCount > 0);
    const health = host.panelHealth();
    const dot = host.root.querySelector<HTMLElement>(".cc-status-dot");
    if (dot) dot.className = `cc-status-dot ${health.dot}`;
    const footerLabel = host.root.querySelector<HTMLElement>(".cc-footer-label");
    const wantsButton = health.kind === "offline" && health.recovery === "qr";
    if (footerLabel && (footerLabel.tagName === "BUTTON") !== wantsButton) return false;
    if (footerLabel) footerLabel.textContent = health.label;
    return true;
  }

  export function filterBySelectedHome<D extends { readonly did: string; readonly splitParentDid?: string | null }, R extends { readonly homeId?: string; readonly dids: readonly string[] }>(
    host: MenuMijiaWindowsApp,
    devices: readonly D[],
    rooms: readonly R[],
  ): { devices: D[]; rooms: R[] } {
    const selected = host.settings.selectedHomeId;
    if (!selected || !host.homes.some((h) => h.id === selected)) return { devices: [...devices], rooms: [...rooms] };
    const homeRooms = rooms.filter((r) => r.homeId === selected);
    const dids = new Set(homeRooms.flatMap((r) => r.dids));
    const kept = devices.filter((d) => dids.has(d.did) || (d.splitParentDid ? dids.has(d.splitParentDid) : false));
    const keptSet = new Set(kept);
    const parents = new Set(kept.map((d) => d.splitParentDid).filter((x): x is string => !!x));
    const withParents = devices.filter((d) => keptSet.has(d) || parents.has(d.did));
    return { devices: withParents, rooms: homeRooms };
  }

export interface HostMultiAccountState {
  readonly accounts: readonly MiAccount[];
  readonly merged: MergedMiAccountsSnapshot | null;
  readonly children: Readonly<Record<string, AccountChildSnapshot>>;
}

export function getHostMiAccountsStore(host: MenuMijiaWindowsApp): MiAccountsStore {
  if (!host.miAccountsStore) {
    host.miAccountsStore = new MiAccountsStore(host.credentialVault);
  }
  return host.miAccountsStore;
}

export function setHostMiAccounts(
  host: MenuMijiaWindowsApp,
  accounts: readonly (MiAccount | MiSession)[] | null,
): void {
  if (accounts === null) {
    host.miAccountsOverride = null;
    return;
  }
  host.miAccountsOverride = accounts.map((entry) => ("session" in entry ? entry : makeMiAccount(entry)));
}

export function getHostMiAccountsState(host: MenuMijiaWindowsApp): HostMultiAccountState | null {
  return host.multiAccountState;
}

export function hasMultipleMiAccountsForHost(host: MenuMijiaWindowsApp): boolean {
  if (host.miAccountsOverride !== null) return host.miAccountsOverride.length > 1;
  return hasSecondaryMiAccountsInIndex();
}

function knownPreferenceIdsForHost(host: MenuMijiaWindowsApp): Set<string> {
  const ids = new Set<string>();
  const layout = host.settings.layout;
  for (const id of layout.pinnedDeviceIds ?? []) ids.add(id);
  for (const id of layout.hiddenDeviceIds ?? []) ids.add(id);
  for (const id of layout.order) ids.add(id);
  for (const id of Object.keys(layout.aliases)) ids.add(id);
  for (const id of Object.keys(layout.groupMap)) ids.add(id);
  for (const key of Object.keys(layout.tileSizes)) {
    const bar = key.indexOf("|");
    ids.add(bar >= 0 ? key.slice(bar + 1) : key);
  }
  for (const id of Object.keys(host.settings.allOffOverrides)) ids.add(id);
  return ids;
}

function applySynthesizedSnapshotToHost(
  host: MenuMijiaWindowsApp,
  home: {
    readonly devices: readonly SmartDevice[];
    readonly deviceFacets?: Readonly<Record<string, readonly import("../core/models.js").FacetControl[]>>;
    readonly environmentReadings: readonly import("../core/models.js").EnvironmentReading[];
    readonly scenes: readonly import("../core/models.js").HomeScene[];
  },
  groupOwners: Map<string, string>,
): void {
  host.groupOwnerByMemberDid = groupOwners;
  const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
  host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
  host.deviceFacets = merged.deviceFacets;
  if (
    host.cameraLive.activeLiveCameraId !== null &&
    !host.devices.some((device) => device.id === host.cameraLive.activeLiveCameraId)
  ) {
    host.cameraLive.closeCameraLiveView();
  }
  const readingPriorityById = new Map(
    host.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
  );
  host.environmentReadings = applyOrder(
    host.environmentReadings.map((reading) => reading.id),
    home.environmentReadings,
  ).sort((a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0));
}

export async function refreshMultiAccountXiaomiDevices(
  host: MenuMijiaWindowsApp,
  silent = false,
): Promise<void> {
  if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "xiaomiCloud" || host.isSyncingCloud) {
    return;
  }
  if (silent && (await isWorkstationLocked())) return;
  const loadedFromStore = host.miAccountsOverride ?? (await getHostMiAccountsStore(host).load());
  const accounts =
    loadedFromStore.length > 0
      ? loadedFromStore
      : host.settings.miSession
        ? [makeMiAccount(host.settings.miSession)]
        : [];
  if (accounts.length === 0 || !isHostAttachedToActiveWindow(host) || host.isSyncingCloud) return;

  const stateRevisionAtStart = host.localControlRevision;
  const syncGen = ++host.syncGeneration;
  const previousPresentation = cloudPresentationFingerprint(host);
  const previousStructure = cloudPanelStructureFingerprint(host);
  const staleBefore = host.cloudValuesStale;
  const expiredBefore = host.miSessionExpired;
  let presentationChanged = false;
  host.isSyncingCloud = true;
  host.lastCloudRefreshAt = Date.now();

  try {
    const prevState = host.multiAccountState;
    const { merged, children } = await refreshMiAccountsConcurrently({
      accounts,
      transport: host.transport,
      specResolver: host.specResolver,
      selectedHomeId: host.settings.selectedHomeId,
      silent,
      previousSnapshots: prevState?.children,
    });
    if (
      !isHostAttachedToActiveWindow(host) ||
      host.settings.connectionMode !== "xiaomiCloud" ||
      host.localControlRevision !== stateRevisionAtStart ||
      host.syncGeneration !== syncGen
    ) {
      return;
    }

    for (const account of accounts) {
      const child = children[account.id];
      if (child?.error) {
        appDiagnosticsLog.record({
          error: child.error,
          category:
            child.error instanceof MiCloudError && child.error.kind === "sessionExpired"
              ? "auth"
              : isXiaomiRateLimitError(child.error)
                ? "rateLimit"
                : "miCloud",
          statusCode: child.error instanceof MiCloudError ? (child.error.code ?? null) : null,
          forbiddenLiterals: [
            account.id,
            account.session.userId,
            account.session.cUserId,
            account.session.serviceToken,
            account.session.ssecurity,
          ],
        });
      }
    }

    host.multiAccountState = { accounts, merged, children };
    if (merged.resetSelectedHome) {
      host.settings.selectedHomeId = null;
    }
    if (merged.homes.length > 0 || host.homes.length === 0) {
      host.homes = applyOrder(host.homes.map((h) => h.id), merged.homes);
    }

    const allExpired = accounts.every((acc) => merged.accountTokenStatuses[acc.id]?.kind === "expired");
    host.miSessionExpired = allExpired;
    if (merged.aggregateStatus.kind === "disconnected") {
      host.markCloudValuesStale();
      if (merged.home.devices.length > 0) {
        applySynthesizedSnapshotToHost(host, merged.home, merged.lightGroupOwners);
        presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
      }
      if (merged.resetSelectedHome) host.saveSettings();
    } else {
      host.markCloudValuesFresh();
      applySynthesizedSnapshotToHost(host, merged.home, merged.lightGroupOwners);
      presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
      markTimerSnapshotReady(host);
      host.settings.cachedXiaomiDevices = host.devices;
      if (presentationChanged || merged.resetSelectedHome) {
        host.saveSettings();
      }
    }

    if (!silent) {
      const isErr = merged.aggregateStatus.kind === "disconnected" && merged.home.devices.length === 0;
      host.replyBanner = isErr
        ? {
            text: t("米家云同步失败：{message}", { message: merged.aggregateStatus.reason }),
            source: t("连接异常"),
            isError: true,
          }
        : {
            text:
              merged.home.devices.length > 0
                ? t("已同步 {count} 台真实米家设备", { count: merged.home.devices.length })
                : t("当前小米账号下暂未发现米家设备"),
            source: t("米家云直连"),
          };
    }
  } finally {
    if (host.syncGeneration === syncGen) {
      host.isSyncingCloud = false;
      if (isHostAttachedToActiveWindow(host)) {
        const staleChanged = staleBefore !== host.cloudValuesStale;
        const expiredChanged = expiredBefore !== host.miSessionExpired;
        if (!silent) {
          host.render();
        } else if (staleChanged || expiredChanged) {
          host.queueBackgroundRender();
        } else if (presentationChanged) {
          if (cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)) {
            host.queueBackgroundRender();
          }
        }
      }
    }
  }
}

export function canUseDualSource(host: MenuMijiaWindowsApp): boolean {
  if (host.settings.connectionMode === "demo") return false;
  const hasHA = homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken) !== null;
  if (!hasHA) return false;
  const override = host.miAccountsOverride;
  const hasMi =
    (override !== null && override.length > 0) ||
    host.settings.miSession !== null ||
    hasSecondaryMiAccountsInIndex();
  return hasMi;
}

export function isDualSourceEnabled(host: MenuMijiaWindowsApp): boolean {
  if (!canUseDualSource(host)) return false;
  if (host.dualSourceEnabledOverride !== null) return host.dualSourceEnabledOverride;
  if (typeof host.settings.dualSourceEnabled === "boolean") return host.settings.dualSourceEnabled;
  try {
    return typeof localStorage !== "undefined" && localStorage.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

export function setHostDualSourceEnabled(
  host: MenuMijiaWindowsApp,
  enabled: boolean,
  options: { readonly persist?: boolean } = {},
): void {
  host.dualSourceEnabledOverride = enabled;
  host.settings.dualSourceEnabled = enabled;
  if (options.persist) {
    try {
      if (typeof localStorage !== "undefined") {
        if (enabled) localStorage.setItem(DUAL_SOURCE_ENABLED_STORAGE_KEY, "1");
        else localStorage.removeItem(DUAL_SOURCE_ENABLED_STORAGE_KEY);
      }
    } catch {
      return;
    }
  }
}

export function setHostHAInvokeOverride(host: MenuMijiaWindowsApp, invoke: HAInvoke | null): void {
  host.haInvokeOverride = invoke;
}

export function getHostDualSourceCoordinator(host: MenuMijiaWindowsApp): DualSourceCoordinator {
  if (!host.dualSourceCoordinator) {
    host.dualSourceCoordinator = new DualSourceCoordinator(undefined, {
      onRecompute: (merged) => {
        applyDualSourceMergeToHost(host, merged);
        if (isHostAttachedToActiveWindow(host)) host.render();
      },
    });
  }
  return host.dualSourceCoordinator;
}

export function getHostDualSourceState(host: MenuMijiaWindowsApp): DeviceMergeResult | null {
  return host.dualSourceCoordinator?.getLastMerged() ?? null;
}

export function setHostDeviceSourcePin(
  host: MenuMijiaWindowsApp,
  deviceId: string,
  backend: HomeBackend | null,
): DeviceMergeResult | null {
  const coordinator = getHostDualSourceCoordinator(host);
  coordinator.pinStorage.pin(deviceId, backend);
  return coordinator.getLastMerged();
}

export function recomputeHostDualSource(host: MenuMijiaWindowsApp): DeviceMergeResult | null {
  const coordinator = getHostDualSourceCoordinator(host);
  const merged = coordinator.recompute(host.settings.interfaceLanguage);
  if (merged) {
    applyDualSourceMergeToHost(host, merged);
    if (isHostAttachedToActiveWindow(host)) host.render();
  }
  return merged;
}

function applyDualSourceMergeToHost(host: MenuMijiaWindowsApp, merged: DeviceMergeResult): void {
  if (merged.homes.length > 0 || host.homes.length === 0) {
    host.homes = applyOrder(host.homes.map((h) => h.id), merged.homes);
  }
  const groupOwners = new Map<string, string>(merged.lightGroupOwners);
  applySynthesizedSnapshotToHost(host, merged.home, groupOwners);
  host.scenes = [...merged.home.scenes];
}

export async function refreshDualSourceDevices(
  host: MenuMijiaWindowsApp,
  silent = false,
): Promise<void> {
  if (!isHostAttachedToActiveWindow(host) || host.isSyncingCloud) return;
  if (silent && (await isWorkstationLocked())) return;

  const endpoint = host.settings.haBaseURL;
  const token = host.settings.haToken;
  const overrideAccounts = host.miAccountsOverride;
  const loadedAccounts =
    overrideAccounts ??
    (host.settings.miSession && !hasSecondaryMiAccountsInIndex()
      ? [makeMiAccount(host.settings.miSession)]
      : await getHostMiAccountsStore(host).load());
  const accounts =
    loadedAccounts.length > 0
      ? loadedAccounts
      : host.settings.miSession
        ? [makeMiAccount(host.settings.miSession)]
        : [];
  if (accounts.length === 0) return;

  const revision = host.localControlRevision;
  const syncGen = ++host.syncGeneration;
  const previousPresentation = cloudPresentationFingerprint(host);
  const previousStructure = cloudPanelStructureFingerprint(host);
  let presentationChanged = false;
  let failed = false;
  host.isSyncingCloud = true;
  host.lastCloudRefreshAt = Date.now();

  try {
    await host.endpointSubmission;
    const coordinator = getHostDualSourceCoordinator(host);
    const prevMiState = host.multiAccountState;
    const haInvoke = host.haInvokeOverride ?? undefined;
    let haRawSnapshot: unknown = null;

    const outcome = await coordinator.refreshParallel({
      knownPreferenceIds: knownPreferenceIdsForHost(host),
      languagePreference: host.settings.interfaceLanguage,
      fetchHA: async (): Promise<DualSourceInputSnapshot> => {
        const res = await fetchHASnapshotWithIdentities(endpoint, token, haInvoke);
        haRawSnapshot = res.rawSnapshot;
        return { home: res.home, identities: res.identities };
      },
      fetchMi: async (): Promise<DualSourceInputSnapshot> => {
        const { merged, children } = await refreshMiAccountsConcurrently({
          accounts,
          transport: host.transport,
          specResolver: host.specResolver,
          selectedHomeId: host.settings.selectedHomeId,
          silent,
          previousSnapshots: prevMiState?.children,
        });
        host.multiAccountState = { accounts, merged, children };
        if (merged.aggregateStatus.kind === "disconnected" && merged.home.devices.length === 0) {
          throw new Error(merged.aggregateStatus.reason);
        }
        const allRawRecords: MiDeviceRecord[] = [];
        const seenDids = new Set<string>();
        for (const acc of accounts) {
          for (const rec of merged.rawDevicesByAccount[acc.id] ?? []) {
            if (!seenDids.has(rec.did)) {
              seenDids.add(rec.did);
              allRawRecords.push(rec);
            }
          }
        }
        return {
          home: merged.home,
          identities: extractMiDeviceIdentities(allRawRecords, merged.home),
          lightGroupOwners: merged.lightGroupOwners,
          homes: merged.homes,
          accountStatuses: merged.accountStatuses,
        };
      },
    });

    if (
      !isHostAttachedToActiveWindow(host) ||
      host.localControlRevision !== revision ||
      host.syncGeneration !== syncGen
    ) {
      return;
    }

    if (outcome.haError) {
      appDiagnosticsLog.record({
        summary: outcome.haError,
        category: "homeAssistant",
        forbiddenLiterals: [endpoint, token],
      });
    }
    if (outcome.miError) {
      appDiagnosticsLog.record({
        summary: outcome.miError,
        category: "miCloud",
        forbiddenLiterals: accounts.flatMap((a) => [a.id, a.session.userId, a.session.serviceToken, a.session.ssecurity]),
      });
    }

    host.haConnectionError = outcome.haError;
    host.markCloudValuesFresh();
    applyDualSourceMergeToHost(host, outcome.merged);
    if (haRawSnapshot && typeof haRawSnapshot === "object") {
      void ingestHostHASnapshotForDoorbell(host, haRawSnapshot as HASnapshotLike);
    }
    markTimerSnapshotReady(host);
    presentationChanged = cloudPresentationFingerprint(host) !== previousPresentation;
    if (presentationChanged) host.saveSettings();
    if (!silent) {
      host.replyBanner = {
        text: tr3(
          `双源并行已融合 ${outcome.merged.home.devices.length} 台设备`,
          `雙源並行已融合 ${outcome.merged.home.devices.length} 台裝置`,
          `Merged ${outcome.merged.home.devices.length} device(s) from Home Assistant + Xiaomi Cloud`,
        ),
        source: tr3("HA + 米家双源", "HA + 米家雙源", "HA + Xiaomi Dual Source"),
      };
    }
  } catch (error) {
    if (!isHostAttachedToActiveWindow(host) || host.localControlRevision !== revision || host.syncGeneration !== syncGen) {
      return;
    }
    failed = true;
    const msg = error instanceof Error ? error.message : String(error);
    host.haConnectionError = msg;
    host.markCloudValuesStale();
    if (!silent) {
      host.replyBanner = {
        text: tr3(
          `双源同步失败：${msg}`,
          `雙源同步失敗：${msg}`,
          `Dual-source sync failed: ${msg}`,
        ),
        source: t("连接异常"),
        isError: true,
      };
    }
    appDiagnosticsLog.record({
      error,
      category: "network",
      forbiddenLiterals: [endpoint, token],
    });
  } finally {
    if (host.syncGeneration === syncGen) {
      host.isSyncingCloud = false;
      if (isHostAttachedToActiveWindow(host)) {
        if (!silent) {
          host.render();
        } else if (
          failed ||
          (presentationChanged &&
            (cloudPanelStructureFingerprint(host) !== previousStructure || !patchCloudPresentation(host)))
        ) {
          host.queueBackgroundRender();
        }
      }
    }
  }
}
