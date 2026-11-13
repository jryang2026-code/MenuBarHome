import { markTimerSnapshotReady } from "./scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { MiCloudClient, MiCloudError, MiotSynthesizer, normalizeMiCloudRegion, type MiRoom, type MiSession, type MiotPropKey } from "../core/miCloudClient.js";
import { discoverMiHome } from "../core/miCloud/discovery.js";
import { HomeAssistantClient, homeAssistantIdentity } from "../core/homeAssistant.js";
import { applyOrder, homeOptions, pageSections, scopedKey, spans, withAliases } from "./panelPrefs.js";
import { filterByListCut, foldGroupedLights, kindChips, memberGroupOwners, showsKindRow } from "./listCut.js";
import { hasMatchingDomShape, morphMatchingDom, parseSingleElement } from "./dom.js";
import { environmentReadingPriority, type SmartDevice } from "../core/models.js";
import { isHostAttachedToActiveWindow, mergeHomeSnapshotRespectingLocks } from "../core/optimisticLock.js";
import { availableQuickActions } from "../core/quickActions.js";
import { renderSliderDeck } from "./panelView.js";

export function foldGrouped(host: MenuMijiaWindowsApp, devices: readonly SmartDevice[]): SmartDevice[] {
    return host.settings.hideGroupedLights
      ? foldGroupedLights(devices, host.groupOwnerByMemberDid)
      : [...devices];
  }


const lastGoodXiaomiRoomsByHost = new WeakMap<
  MenuMijiaWindowsApp,
  {
    readonly sourceRevision: number;
    readonly userId: string;
    readonly region: string;
    readonly rooms: readonly MiRoom[];
  }
>();

export async function refreshDevices(host: MenuMijiaWindowsApp, silent = false): Promise<void> {
    if (!isHostAttachedToActiveWindow(host)) return;
    if (host.settings.connectionMode === "homeAssistant") return refreshHADevices(host, silent);
    if (!host.settings.miSession || host.settings.connectionMode !== "xiaomiCloud" || host.isSyncingCloud) return;
    const session = host.settings.miSession;
    const normalizedRegion = normalizeMiCloudRegion(session.region);
    const previousPresentation = cloudPresentationFingerprint(host);
    const previousStructure = cloudPanelStructureFingerprint(host);
    const staleBefore = host.cloudValuesStale;
    const expiredBefore = host.miSessionExpired;
    const stateRevisionAtStart = host.localControlRevision;
    const selectedHomeAtStart = host.settings.selectedHomeId;
    const syncGen = ++host.syncGeneration;
    let presentationChanged = false;
    host.isSyncingCloud = true;
    host.lastCloudRefreshAt = Date.now();
    if (!silent) {
      host.render();
    }

    try {
      const client = new MiCloudClient(session, host.transport);
      const discovery = await discoverMiHome(client, {
        unresolvedDids: host.unresolvedRoomDids,
        retryUnresolved: !silent,
        cachedRooms: () => {
          const cached = lastGoodXiaomiRoomsByHost.get(host);
          return cached &&
            cached.sourceRevision === host.sourceRevision &&
            cached.userId === session.userId &&
            cached.region === normalizedRegion
            ? cached.rooms
            : null;
        },
        onRoomsRead: (rooms) => {
          lastGoodXiaomiRoomsByHost.set(host, {
            sourceRevision: host.sourceRevision,
            userId: session.userId,
            region: normalizedRegion,
            rooms,
          });
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
      const { devices: rawDevices, rooms } = filterBySelectedHome(host, allDevices, allRooms);
      const groupDids = rawDevices.map((device) => device.did).filter((did) => did.startsWith("group."));
      const membershipByGroup = groupDids.length > 0
        ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
        : Promise.resolve(new Map<string, string[]>());

      // Stage 1: Instant synthesis with cached/fallback specs so user sees their real devices immediately
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

      // Stage 2: Resolve exact MIoT specs + fetch live device properties
      const specs = await host.specResolver.resolveForDevices(rawDevices);
      // Card properties plus the 更多设置 rows (#5), deduped so one snapshot covers both.
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

      let values: Map<string, unknown>;
      try {
        values =
          propKeys.length > 0
            ? await client.getProps(propKeys)
            : new Map<string, unknown>();
      } catch (error) {
        // A failed property read must not rebuild every device from defaults.
        if (!cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) {
          host.markCloudValuesStale();
        }
        throw error;
      }

      const home = MiotSynthesizer.synthesize(rawDevices, rooms, specs, values);
      const membersByGroup = await membershipByGroup;
      // An old refresh must not clear or set freshness for the connection that replaced it.
      if (cloudSnapshotIsStale(host, session, stateRevisionAtStart, syncGen, selectedHomeAtStart)) return;
      host.miSessionExpired = false;
      host.markCloudValuesFresh();
      host.groupOwnerByMemberDid = memberGroupOwners(membersByGroup);
      // Cloud list order is not a layout preference. Keep known devices in their
      // displayed order, use fresh values (while respecting unexpired optimistic locks),
      // drop removed ids and append new ones.
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
        if (err instanceof MiCloudError && err.kind === "sessionExpired") {
          host.miSessionExpired = true;
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
      const home = await new HomeAssistantClient(endpoint, token).snapshot();
      const identity = homeAssistantIdentity(endpoint, token);
      if (!identity) throw new Error("Invalid Home Assistant URL");
      if (!isHostAttachedToActiveWindow(host) || host.settings.connectionMode !== "homeAssistant" || host.settings.haBaseURL !== endpoint || host.settings.haToken !== token || host.localControlRevision !== revision || host.syncGeneration !== syncGen) return;
      const merged = mergeHomeSnapshotRespectingLocks(host, home.devices, home.deviceFacets);
      host.devices = applyOrder(host.devices.map((device) => device.id), merged.devices);
      host.deviceFacets = merged.deviceFacets;
      host.scenes = home.scenes;
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

  /** Cloud state that affects the rendered panel; polling a matching snapshot is a visual no-op. */
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
    );
    const quickActions =
      host.settings.showQuickActionsBar && host.settings.connectionMode !== "demo"
        ? availableQuickActions(foldGrouped(host, filterByListCut(host.devices, host.listCut, false))).map(
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
      allOffTargets: host.settings.connectionMode === "homeAssistant" ? null : host.allOffTargets.map((device) => device.id),
      devices: host.devices.map((device) => {
        const kind = device.kind;
        const capabilities =
          kind.kind === "light"
            ? [
                kind.availableEffects,
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
                          ? [kind.volumeWritable, kind.muteSwitchEntityId, kind.sleepModeEntityId]
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

  /** Narrows cloud records and rooms to the selected Mi Home; split keys bring their parent panel along. */
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
