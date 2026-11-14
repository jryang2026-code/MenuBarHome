import { homeAssistantIdentity } from "../core/homeAssistant.js";
import {
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  inferAssistantPreset,
  partitionHabitReceipt,
  type HabitLastAction,
  type HabitRecordingReceipt,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import {
  type HttpTransport,
  MiAccountLogin,
  MiotSpecResolver,
  type QRLoginTicket,
  maskedMiUserId,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import {
  type GitHubRelease,
  type UpdateState,
} from "../core/updateChecker.js";
import {
  CredentialVault,
  sessionWithoutPassToken,
} from "../core/secureStore.js";
import {
  type AssistantSuggestion,
  type DeviceCommand,
  type DeviceIntent,
  type EnvironmentReading,
  type FacetControl,
  type HomeScene,
  type ScheduledCommand,
  type SmartDevice,
  allOffTargets,
  computeTotalPowerWatts,
  deviceEnvironmentReading,
  environmentReadingPriority,
  isActiveDevice,
} from "../core/models.js";
import {
  type LayoutPrefs,
  type PanelAnchor,
  type PanelPlacement,
  type TileSize,
  PANEL_HEIGHTS,
  applyOrder,
  chosenSize,
  isDevicePinned,
  moveInOrder,
  pageSections,
  parsePanelPlacement,
  resolveAppearance,
  resolvedSize,
  scopedKey,
  spans,
  withAliases,
  type HomeOption,
} from "./panelPrefs.js";
import {
  t,
} from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import {
  KIND_CHIP,
  filterByListCut,
  kindChips,
  showsKindRow,
  type DeviceKindTag,
  type DeviceListCut,
  type RoomOption,
} from "./listCut.js";

import { type LoadedSettings, type PendingHighRiskConfirmation, type PersistedSettings, type ReplyBannerState, type UndoAction, type UndoStep } from "./appTypes.js";
import { SF_ICONS } from "./appConstants.js";
import { demoDevices, demoScenes } from "./demo.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import { loadSettings } from "./settings.js";
import { CameraLiveController } from "./cameraLive.js";
import { renderDeviceTile as renderDeviceTileView, renderEnvironmentStrip as renderEnvironmentStripView } from "./deviceViews.js";
import { renderContextMenu, renderHomeMenu, renderOnboardingModal, renderPrompt, renderSettingsModal } from "./menuViews.js";
import { bindDeckEvents, bindEvents as bindEventsImpl } from "./bindEvents.js";
import { createDefaultHostEnergySession, notifyEnergyDevicesMutated, syncEnergyHostOnRender, type HostEnergySession } from "./energySettingsView.js";
import { syncSensorHistoryHost } from "./sensorHistoryView.js";
import { renderPanel } from "./panelView.js";
import { applyGlobalHotkey, applyInterfaceLanguage, applyTemperatureSetting, bindGlobalKeys, bindLifecycleRecovery, checkForAppUpdate, disposeAppLifecycle, initializeCredentials, openSettingsSheet, openUpdatePage, restoreUpdateState, saveSettings, signOutXiaomiAccount, startTimerLoop, startUpdateInstall, submitServiceEndpoints } from "./appLifecycle.js";
import { handleNaturalCommand, runScheduledCommand } from "./naturalCommand.js";
import { currentProactiveSuggestions, invalidateSourceControl, maybeRefreshProactiveInBackground } from "./proactive.js";
import { bindPersistentUndoEvents, undoTrackerFor } from "./undoTracker.js";
import { getHostApplyCommand, getUnsupportedLightEffects, markCloudValuesFresh, markCloudValuesStale, pruneUnsupportedLightEffectsOnHost, setCustomApplyCommand } from "./commandDispatch.js";
import { getSpeakerDrawerItemState } from "./detailDrawers.js";
import { activeRoomOptions } from "./roomOrderEditor.js";
import { foldGrouped, refreshDevices, refreshHADevices } from "./cloudRefresh.js";
import { executeIntents, executeSingleCommand, getRunningBatch, getUndoActionBatch, habitSequences, lastHabitAction, unrecordHabits } from "./intentExecution.js";
import { clearPersistedMiSessionExpired, persistMiSessionExpired } from "../core/pollingPolicy.js";
import { bindLayoutGestures } from "./layoutGestures.js";
import { bindSettingsEvents, refreshHabitSharePreview } from "./settingsEvents.js";
import { captureSettingsDraft, restoreSettingsDraft, type SettingsTab } from "./settingsViews.js";
import {
  bindUndoBannerHoverGuard, clearUndoHoverPause, copyUndoKindSnapshots, isInsideScheduledTimerTick, isUndoHoverPaused,
  rejectIfControlBlockedWhileLocked, renderUrlConfirmationPrompt, restoreUndoKindSnapshot, runScheduledCommandWithLockGuard, shouldKeepPopoverPinned, syncUndoBannerClock, toggleVoiceInput, undoButtonVisible,
} from "./speechGuard.js";
import { inputKeepsDraft } from "./dom.js";
export { waitForCameraFrameGap } from "./dom.js";
import { createPanelSearchState, normalizeSearch, PanelSearchIndex } from "../core/panelSearch.js";
import { syncPanelSelection } from "./panelKeyboard.js";

import { ScheduledCommandStore } from "../core/scheduledCommands.js";
import { scheduledCommandIdentity } from "./scheduledCommands.js";

export type PanelHealth =
  | { readonly kind: "demo"; readonly dot: "is-demo"; readonly label: string }
  | { readonly kind: "syncing"; readonly dot: "is-syncing"; readonly label: string }
  | { readonly kind: "online"; readonly dot: "is-online"; readonly label: string }
  | { readonly kind: "degraded"; readonly dot: "is-degraded"; readonly label: string }
  | { readonly kind: "offline"; readonly dot: "is-offline"; readonly label: string; readonly recovery: "qr" | "none" };

export { undoBannerMs, undoDeviceCount } from "./undoTracker.js";

function visibleTopSheet(root: ParentNode): HTMLElement | undefined {
  return Array.from(root.querySelectorAll<HTMLElement>(".cc-sheet"))
    .filter((sheet) => sheet.closest<HTMLElement>(".cc-sheet-backdrop")?.style.display !== "none")
    .at(-1);
}

function activeSheetKey(root: ParentNode): string | null {
  const topSheet = visibleTopSheet(root);
  if (!topSheet) return null;
  if (topSheet.classList.contains("cc-camera-live-sheet")) return "camera";
  if (topSheet.classList.contains("cc-settings-sheet")) return "settings";
  return "onboarding";
}

function activeMenuKey(root: ParentNode): string | null {
  const menu = root.querySelector<HTMLElement>(".cc-menu");
  if (!menu) return null;
  return menu.classList.contains("cc-home-menu") ? "home" : "context";
}

export type HaConnectionBlock = "plaintext" | "auth" | "stale" | "none";

function endpointOrigin(raw: string): string | null {
  try {
    const url = new URL(raw.trim());
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    return url.origin;
  } catch {
    return null;
  }
}

/** What the footer should say about a Home Assistant error string. */
export function haConnectionBlock(url: string, message: string): HaConnectionBlock {
  const text = message.trim();
  if (text === "") return "none";
  if (text.includes("Home Assistant authentication rejected")) return "auth";
  const origin = endpointOrigin(url);
  const publicHttp = origin !== null && !endpointAllowsSendingSecrets(url);
  const declinedThisHost = text.includes("未授权的网络来源") && origin !== null && text.includes(origin);
  const unapproved = text.includes("Home Assistant endpoint has not been approved");
  if (publicHttp && (declinedThisHost || unapproved)) return "plaintext";
  return "stale";
}

export class MenuMijiaWindowsApp {
  public readonly loadedSettings: LoadedSettings = loadSettings();
  public settings: PersistedSettings = this.loadedSettings.settings;
  public readonly credentialVault = new CredentialVault();
  /** Per-provider saved API keys in memory (`CODING_STANDARDS.md` §6); never written to localStorage. */
  public assistantKeysByPreset: Record<string, string> = {};
  public lastSubmittedEndpoints: string | null = null;
  // Assigned in the constructor, after the interface language is resolved: the demo home is
  // generated per language (#52), so a field initializer would freeze the module default.
  private _devices: SmartDevice[] = [];
  private devicesMutationScheduled = false;
  public energySession: HostEnergySession = createDefaultHostEnergySession();
  public get devices(): SmartDevice[] {
    return this._devices;
  }
  public set devices(next: SmartDevice[]) {
    this._devices = next;
    notifyEnergyDevicesMutated(this);
    if (!this.devicesMutationScheduled) {
      this.devicesMutationScheduled = true;
      queueMicrotask(() => {
        this.devicesMutationScheduled = false;
        if (this.root.isConnected) {
          syncSensorHistoryHost(this);
          syncEnergyHostOnRender(this);
        }
      });
    }
  }
  /** Device id → 更多设置 rows from the latest snapshot (#5); empty until one arrives. */
  public deviceFacets: Readonly<Record<string, readonly FacetControl[]>> = {};
  public scenes: HomeScene[];
  public environmentReadings: EnvironmentReading[] = [];
  public listCut: DeviceListCut = { kind: "all" };

  public get selectedRoom(): string {
    return this.listCut.kind === "room" ? this.listCut.roomName : "全部";
  }

  /** Room buttons keyed by id: two homes may both have a 客厅. */
  public get roomOptions(): RoomOption[] {
    return activeRoomOptions(this);
  }

  public selectRoom(roomId: string | null, roomName?: string): void {
    this.savedGridScrollTop = 0;
    this.listCut = roomId === null
      ? { kind: "all" }
      : { kind: "room", roomId, roomName: roomName ?? roomId };
  }

  public selectDeviceKind(tag: DeviceKindTag): void {
    this.savedGridScrollTop = 0;
    this.listCut = { kind: "deviceKind", tag };
  }

  public kindTagFromDataset(value: string | undefined): DeviceKindTag | null {
    return value !== undefined && Object.hasOwn(KIND_CHIP, value) ? (value as DeviceKindTag) : null;
  }

  public readonly panelSearch = createPanelSearchState();
  private readonly panelSearchIndex = new PanelSearchIndex();
  public expandedDeviceId: string | null = null;
  private savedGridScrollTop = 0;
  /**
   * A high-risk manual write that needs one more tap on the same card within a few seconds.
   * `actionKey` binds the arm to one exact command, so tapping a different high-risk control
   * on the same device re-arms instead of spending the previous confirmation.
   */
  public pendingHighRisk: PendingHighRiskConfirmation | null = null;
  private pendingHighRiskTimer: number | null = null;
  public isShowingAssistantBar = true;
  public activeSheet: "none" | "onboarding" | "settings" = "none";
  /** Open Settings category (#78); a re-render keeps it, `openSettingsSheet(tab)` routes it. */
  public settingsTab: SettingsTab = "general";
  public replyBanner: ReplyBannerState | null = null;
  public haConnectionError: string | null = null;
  public waitingDeviceIds = new Set<string>();
  /** A Xiaomi refresh failed after devices were already on screen. */
  public cloudValuesStale = false;
  /** Member did → owning light-group did from the latest Xiaomi Cloud refresh (#214). */
  public groupOwnerByMemberDid = new Map<string, string>();
  /** A command waiting for the user to allow sending it to a cloud AI service (#20). */
  public pendingCloudConsent: { utterance: string; endpoint: string } | null = null;
  /** AI guesses that wait for a tap instead of running by themselves (#21). */
  public pendingSuggestions: AssistantSuggestion[] = [];
  /** AI-ranked proactive suggestions for the current ambient signature (#113). */
  public aiProactiveSuggestions: AssistantSuggestion[] | null = null;
  public aiProactiveSignature: string | null = null;
  public isRefreshingProactive = false;
  /** Collapsible Win+N notification cards in the Top Island; quick camera starts compact. */
  public collapsedNotifCards = new Set<string>(["camera"]);
  public panelGeometryUpdates: Promise<void> = Promise.resolve();
  /** Panel anchor the backend persists (#204); the window position itself is owned by Rust. */
  public panelAnchor: PanelAnchor = "auto";
  /** Earliest timestamp a failed background refresh may retry (Codex #116 review). */
  public proactiveRetryAfterMs: number | null = null;
  public isResolvingIntent = false;
  public isSyncingCloud = false;
  public syncGeneration = 0;
  public lastCloudRefreshAt: number | null = null;
  public localControlRevision = 0;
  public sourceRevision = 0;
  /** A silent cloud result that is waiting for the user to finish interacting. */
  public pendingCloudRender = false;
  public endpointSubmission: Promise<unknown> = Promise.resolve();
  public pointerIsDown = false;
  public isListeningVoice = false;
  public readonly scheduledCommandStore = new ScheduledCommandStore(localStorage);
  public timerCredentialsReady = false;
  public timerSnapshot: { identity: string; sourceRevision: number } | null = null;
  public get scheduledCommands(): ScheduledCommand[] {
    return this.scheduledCommandStore.queue(scheduledCommandIdentity(this.settings)).scheduledCommands;
  }
  public set scheduledCommands(items: ScheduledCommand[]) {
    this.scheduledCommandStore.queue(scheduledCommandIdentity(this.settings)).scheduledCommands = items;
  }
  public get missedScheduledCommands(): ScheduledCommand[] {
    return this.scheduledCommandStore.queue(scheduledCommandIdentity(this.settings)).missedScheduledCommands;
  }
  public set missedScheduledCommands(items: ScheduledCommand[]) {
    this.scheduledCommandStore.queue(scheduledCommandIdentity(this.settings)).missedScheduledCommands = items;
  }
  public lastUndoAction: UndoAction | null = null;
  /** Last light explicitly switched on or adjusted by the user; fallback target for `softNightLight` (#36). */
  public lastManuallyUsedLightId: string | null = null;
  /** Set when a Xiaomi refresh fails because the login itself is dead. */
  private _miSessionExpired = false;
  public get miSessionExpired(): boolean {
    return this._miSessionExpired;
  }
  public set miSessionExpired(next: boolean) {
    const normalized = Boolean(next);
    this._miSessionExpired = normalized;
    if (normalized) {
      if (this.settings.miSession) persistMiSessionExpired(this.settings.miSession, true);
    } else {
      clearPersistedMiSessionExpired();
    }
  }
  /** True after a hold already ran All Off, so a later pointerup on the rebuilt button does not replace the result with the short-press hint. */
  private allOffHoldConsumed = false;
  private allOffHoldTimer: number | null = null;
  private readonly appDisposers: Array<() => void> = [];
  public undoBannerUntilMs = 0;
  public qrTicket: QRLoginTicket | null = null;
  public qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
  public isPollingQR = false;
  /** Latest GitHub release found by the daily check (#39); shown in settings and the tray menu. */
  public availableUpdate: GitHubRelease | null = null;
  public updateState: UpdateState = { lastCheckedAtMs: null, release: null };
  public isCheckingUpdate = false;
  public isInstallingUpdate = false;
  public updateStatusMessage: { text: string; isError: boolean } | null = null;
  public readonly transport: HttpTransport = createTransport();
  public readonly specResolver: MiotSpecResolver;
  public readonly cameraLive: CameraLiveController;

  get cameraKeepAliveMs(): number { return this.cameraLive.cameraKeepAliveMs; }
  set cameraKeepAliveMs(ms: number) { this.cameraLive.cameraKeepAliveMs = ms; }

  // Personalisation / layout editing state (see panelPrefs.ts).
  public homes: HomeOption[] = [];
  public isHomeMenuOpen = false;
  public isEditingLayout = false;
  public draggingId: string | null = null;
  public dragPointer: { x: number; y: number; grabX: number; grabY: number } | null = null;
  public lastSwap: { slot: string; at: number } | null = null;
  public ctxMenu: {
    x: number;
    y: number;
    deviceId?: string;
    groupId?: string;
    roomTarget?: { readonly roomId: string; readonly originalName: string };
    kindTarget?: DeviceKindTag;
    roomBar?: boolean;
  } | null = null;
  public prompt:
    | { kind: "newGroup"; deviceId: string }
    | { kind: "renameGroup"; groupId: string }
    | { kind: "renameDevice"; deviceId: string }
    | { kind: "roomOrderEditor" }
    | null = null;
  public animateEntrance = false;
  public poppedDeviceId: string | null = null;
  public dimPreview: { id: string; percent: number } | null = null;
  public suppressNextClick = false;
  public isRecordingHotkey = false;
  public hotkeyNeedsHint = false;
  public hotkeyRegistrationError: string | null = null;

  constructor(public readonly root: HTMLElement) {
    this.specResolver = new MiotSpecResolver(
      this.transport,
      undefined,
      this.settings.cachedModelTypes,
    );
    this.cameraLive = new CameraLiveController(this);

    this.applyInterfaceLanguage();
    this.qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
    this.applyTemperatureSetting();
    const haCache = this.settings.cachedHAHome?.identity === homeAssistantIdentity(this.settings.haBaseURL, this.settings.haToken) ? this.settings.cachedHAHome.home : null;
    this.devices = this.settings.connectionMode === "xiaomiCloud"
      ? structuredClone(this.settings.cachedXiaomiDevices)
      : this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.devices ?? []) : demoDevices();
    this.scenes = this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.scenes ?? []) : this.settings.connectionMode === "demo" ? demoScenes() : [];
    this.environmentReadings = this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.environmentReadings ?? []) : [];
    // 更多设置 rows come back with the cached cards: without them the restored panel shows every
    // auxiliary control as missing until the first live snapshot lands.
    this.deviceFacets = this.settings.connectionMode === "homeAssistant"
      ? structuredClone(haCache?.deviceFacets ?? {})
      : {};
    this.initializeCredentials();
    this.submitServiceEndpoints();

    if (!this.settings.hasCompletedOnboarding && !this.settings.miSession) {
      this.activeSheet = "onboarding";
    }

    this.bindGlobalKeys();
    bindUndoBannerHoverGuard(this);
    // Alt+Tab hides the popover without a button blur; a hold started before it must not finish.
    const onBlurCancelAllOff = () => this.cancelAllOffHold();
    window.addEventListener("blur", onBlurCancelAllOff);
    this.appDisposers.push(
      () => window.removeEventListener("blur", onBlurCancelAllOff),
      () => undoTrackerFor(this).dispose(),
    );
    this.bindLayoutGestures();
    this.bindPanelDrag();
    this.bindOpenAnimation();
    const onOpenUpdate = () => {
      this.openSettingsSheet();
    };
    window.addEventListener("menumijia:open-update", onOpenUpdate);
    this.appDisposers.push(() => window.removeEventListener("menumijia:open-update", onOpenUpdate));
    this.applyPanelHeight();
    this.syncPanelPlacement();
    this.syncPanelBackdrop();
    void this.applyGlobalHotkey();
    this.bindLifecycleRecovery();
    this.startTimerLoop();
    this.restoreUpdateState();
    this.render();

    if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
      void this.refreshDevices();
    }
    // At most one GitHub request per local day, and only inside the packaged app (#39).
    void this.checkForAppUpdate(false);
  }

  private initializeCredentials(): void {
    initializeCredentials(this);
  }



  public saveSettings(forceSubmitEndpoints = false): void {
    saveSettings(this, forceSubmitEndpoints);
  }

  public applyInterfaceLanguage(): void {
    applyInterfaceLanguage(this);
  }

  public applyTemperatureSetting(): void {
    applyTemperatureSetting(this);
  }

  private submitServiceEndpoints(force = false): void {
    submitServiceEndpoints(this, force);
  }

  private restoreUpdateState(): void {
    restoreUpdateState(this);
  }

  public async checkForAppUpdate(manual: boolean): Promise<void> {
    return checkForAppUpdate(this, manual);
  }

  public openSettingsSheet(tab: SettingsTab = "general"): void {
    openSettingsSheet(this, tab);
  }

  public openUpdatePage(): void {
    openUpdatePage(this);
  }

  public async startUpdateInstall(): Promise<void> {
    return startUpdateInstall(this);
  }

  public async applyGlobalHotkey(): Promise<void> {
    return applyGlobalHotkey(this);
  }

  private bindGlobalKeys(): void {
    bindGlobalKeys(this);
  }

  private bindLifecycleRecovery(): void {
    bindLifecycleRecovery(this, { onPageHide: () => this.dispose() });
  }

  private startTimerLoop(): void {
    startTimerLoop(this);
  }

  /** Idempotently cancels lifecycle intervals, recovery timers, and global window listeners. */
  public dispose(): void {
    disposeAppLifecycle(this);
    this.clearPendingHighRisk();
    this.cancelAllOffHold();
    for (const stop of this.appDisposers.splice(0)) stop();
    if (this.cameraLive.activeLiveCameraId !== null || this.cameraLive.liveCameraKeepAliveTimer !== null) {
      this.cameraLive.closeCameraLiveView();
    }
  }

  /** The tray popover hides when it loses focus, so focus means it is on screen. */
  public isPanelVisible(): boolean {
    return document.visibilityState !== "hidden" && document.hasFocus();
  }

  /** Background refreshes must not rebuild the panel while the user is mid-action. */
  public hasBlockingPanelInteraction(): boolean {
    return (
      this.activeSheet !== "none" ||
      this.pointerIsDown ||
      this.isListeningVoice ||
      this.allOffHoldTimer !== null ||
      this.draggingId !== null ||
      this.isEditingLayout ||
      this.isHomeMenuOpen ||
      this.ctxMenu !== null ||
      this.prompt !== null
    );
  }

  /** Applies a background result only when it cannot clear focus or cancel a pointer gesture. */
  public queueBackgroundRender(): void {
    if (this.hasBlockingPanelInteraction()) {
      this.pendingCloudRender = true;
      return;
    }
    this.render();
  }

  private get filteredDevices(): SmartDevice[] {
    const query = normalizeSearch(this.panelSearch.query);
    if (!query) return filterByListCut(this.devices, this.listCut, this.settings.hideOfflineDevices, { layout: this.layout });
    const candidates = filterByListCut(this.devices, { kind: "all" }, this.settings.hideOfflineDevices, { layout: this.layout });
    const byId = new Map(candidates.map((device) => [device.id, device]));
    return this.panelSearchIndex.matches(query, candidates, this.layout.aliases).flatMap((entry) => {
      const device = byId.get(entry.deviceId);
      return device ? [device] : [];
    });
  }

  /** Cards on screen: the list cut, plus folding member lights into a visible group card (#214). */
  public get presentationDevices(): SmartDevice[] {
    return this.foldGrouped(this.filteredDevices);
  }

  private foldGrouped(devices: readonly SmartDevice[]): SmartDevice[] {
    return foldGrouped(this, devices);
  }

  public get activeDeviceCount(): number {
    return this.devices.filter((d) => isActiveDevice(d)).length;
  }

  private get onlineDeviceCount(): number {
    return this.devices.filter((d) => d.isOnline).length;
  }

  private get totalPowerWatts(): number {
    return computeTotalPowerWatts(this.devices);
  }

  public get computedEnvironmentReadings(): EnvironmentReading[] {
    if (this.environmentReadings.length > 0) {
      const priorityById = new Map(
        this.devices.map((d) => [d.id, environmentReadingPriority(d.kind)]),
      );
      return [...this.environmentReadings].sort(
        (a, b) => (priorityById.get(a.id) ?? 0) - (priorityById.get(b.id) ?? 0),
      );
    }
    const out: Array<{ reading: EnvironmentReading; priority: number; index: number }> = [];
    for (let i = 0; i < this.devices.length; i++) {
      const d = this.devices[i]!;
      const reading = deviceEnvironmentReading(d);
      if (reading) {
        out.push({
          reading,
          priority: environmentReadingPriority(d.kind),
          index: i,
        });
      }
    }
    out.sort((a, b) => a.priority - b.priority || a.index - b.index);
    return out.map((item) => item.reading);
  }

  /**
   * Rooms of homes shared with this account name devices the unfiltered list leaves out; look them
   * up by did (#134). Dids the lookup cannot resolve (IR remotes, removed devices) are skipped on
   * silent refreshes so polling does not spend a request on them every time.
   */
  public unresolvedRoomDids = new Set<string>();


  public async refreshDevices(silent = false): Promise<void> {
    return refreshDevices(this, silent);
  }

  public async refreshHADevices(silent = false): Promise<void> {
    return refreshHADevices(this, silent);
  }





  public selectHome(id: string | null): void {
    this.settings.selectedHomeId = id;
    this.isHomeMenuOpen = false;
    this.selectRoom(null);
    this.lastUndoAction = null;
    clearUndoHoverPause(this);
    // Invalidate any in-flight cloud refresh from the previous home so it cannot overwrite the new selection.
    this.localControlRevision += 1;
    this.syncGeneration += 1;
    this.isSyncingCloud = false;
    // A different home is a different suggestion context even at the same ambient signature (Codex #116 review).
    this.aiProactiveSuggestions = null;
    this.aiProactiveSignature = null;
    this.isRefreshingProactive = false;
    this.proactiveRetryAfterMs = null;
    this.applyPanelHeight();
    this.saveSettings();
    this.render();
    void this.refreshDevices(false);
  }

  public get homeTitle(): string {
    const h = this.homes.find((x) => x.id === this.settings.selectedHomeId);
    return h ? h.name : this.homes.length > 1 ? t("全部家庭") : t("我的米家");
  }

  /** Devices 全关 would switch off: on screen (current room), on, and taking part (#23). */
  public get allOffTargets(): SmartDevice[] {
    return allOffTargets(this.filteredDevices, this.settings.allOffOverrides);
  }

  public renderKindBar(): string {
    const chips = kindChips(this.devices, this.listCut, this.settings.hideOfflineDevices, { layout: this.layout });
    if (!showsKindRow(chips, this.listCut)) return "";
    const buttons = chips.map((tag) => {
      const chip = KIND_CHIP[tag];
      const active = this.listCut.kind === "deviceKind" && this.listCut.tag === tag;
      const hint = chip.hint ? ` title="${this.escapeHtml(t(chip.hint))}"` : "";
      return `<button class="cc-room-pill is-kind${active ? " is-active" : ""}" data-kind="${tag}" aria-pressed="${active}"${hint}>${this.escapeHtml(t(chip.title))}</button>`;
    }).join("");
    return `<span class="cc-filter-sep" aria-hidden="true"></span>${buttons}`;
  }

  private allOffButtonText(count: number): string {
    if (this.listCut.kind === "all") return `${t("全关")} (${count})`;
    const scope = this.listCut.kind === "room"
      ? this.listCut.roomName
      : t(KIND_CHIP[this.listCut.tag].title);
    return `${t("全关·{room}", { room: this.escapeHtml(scope) })} (${count})`;
  }

  public renderAllOffControl(): string {
    if (this.isEditingLayout) return `<button class="cc-all-off-pill is-done" id="btn-done-editing" aria-label="${t("完成布局编辑")}">${t("完成")}</button>`;
    const count = this.allOffTargets.length;
    if (count === 0) return "";
    return `<button class="cc-all-off-pill is-hold" id="btn-all-off" title="${t("按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与，可在设置里调整）", { count })}" aria-label="${t("全关，关闭 {count} 台设备，按住 0.6 秒确认", { count })}">
      <span class="cc-hold-fill"></span>
      ${SF_ICONS.power}
      <span>${this.allOffButtonText(count)}</span>
    </button>`;
  }

  private clearAllOffHold(): void {
    if (this.allOffHoldTimer !== null) {
      window.clearTimeout(this.allOffHoldTimer);
      this.allOffHoldTimer = null;
    }
  }

  /** Losing window focus disarms the hold without the short-press hint. */
  private cancelAllOffHold(): void {
    this.clearAllOffHold();
    this.root.querySelector<HTMLElement>("#btn-all-off")?.classList.remove("is-holding");
  }

  public bindAllOffControl(): void {
    this.clearAllOffHold();
    const allOff = this.root.querySelector<HTMLElement>("#btn-all-off");
    if (!allOff) return;
    const beginHold = () => {
      if (this.allOffHoldTimer !== null) return;
      this.allOffHoldConsumed = false;
      allOff.classList.add("is-holding");
      this.allOffHoldTimer = window.setTimeout(() => {
        this.allOffHoldTimer = null;
        // The popover hides on window blur but the button stays in the DOM: never fire a hold the
        // user cannot see finish.
        if (!allOff.isConnected || !document.hasFocus()) return;
        this.allOffHoldConsumed = true;
        allOff.classList.remove("is-holding");
        void this.turnAllOff();
      }, 600);
    };
    // A keyup after the button was rebuilt has no pending timer, so it must not show the short-press hint.
    const endHold = (hint: "never" | "if-pending" | "always") => {
      const pending = this.allOffHoldTimer !== null;
      this.clearAllOffHold();
      allOff.classList.remove("is-holding");
      const showHint = !this.allOffHoldConsumed && (hint === "always" || (hint === "if-pending" && pending));
      if (!showHint) return;
      this.replyBanner = { text: t("按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与）", { count: this.allOffTargets.length }), source: t("提示") };
      this.render();
    };
    const isHoldKey = (event: KeyboardEvent) => event.key === " " || event.key === "Spacebar" || event.key === "Enter";
    allOff.addEventListener("pointerdown", () => beginHold());
    allOff.addEventListener("pointerup", () => endHold("always"));
    allOff.addEventListener("pointerleave", () => endHold("never"));
    allOff.addEventListener("blur", () => {
      this.clearAllOffHold();
      allOff.classList.remove("is-holding");
    });
    allOff.addEventListener("keydown", (event) => {
      if (!isHoldKey(event)) return;
      event.preventDefault();
      event.stopPropagation();
      if (event.repeat) return;
      beginHold();
    });
    allOff.addEventListener("keyup", (event) => {
      if (!isHoldKey(event)) return;
      event.preventDefault();
      event.stopPropagation();
      endHold("if-pending");
    });
  }

  private async turnAllOff(): Promise<void> {
    const targets = this.allOffTargets;
    if (targets.length === 0) return;
    const intents: DeviceIntent[] = targets.map((d) => ({
      targetId: d.id,
      operation: { kind: "power", isOn: false },
    }));
    await this.executeIntents(
      intents,
      t("已关闭 {count} 台开启中的设备", { count: targets.length }),
      t("一键全关"),
      { recordHabits: true },
    );
  }

  public async handleNaturalCommand(rawInput: string, fromScheduled = false): Promise<void> {
    if (!isInsideScheduledTimerTick() && (await rejectIfControlBlockedWhileLocked(this))) return;
    return handleNaturalCommand(this, rawInput, fromScheduled);
  }

  public async runScheduledCommand(item: ScheduledCommand): Promise<void> {
    return runScheduledCommandWithLockGuard(this, item, () => runScheduledCommand(this, item));
  }

  public async executeIntents(
    intents: readonly DeviceIntent[],
    replyText: string,
    sourceLabel: string,
    options: { recordHabits?: boolean } = {},
  ): Promise<boolean> {
    if (!isInsideScheduledTimerTick() && (await rejectIfControlBlockedWhileLocked(this))) return false;
    return executeIntents(this, intents, replyText, sourceLabel, options);
  }

  public async executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower = false,
  ): Promise<void> {
    if (await rejectIfControlBlockedWhileLocked(this)) return;
    return executeSingleCommand(this, device, command, summary, intent, readBackPower);
  }


  public habitSequences(): HabitSequenceEntry[] {
    return habitSequences();
  }

  public lastHabitAction(): HabitLastAction | null {
    return lastHabitAction();
  }

  private unrecordHabits(receipt: HabitRecordingReceipt): void {
    unrecordHabits(this, receipt);
  }

  public currentProactiveSuggestions(): AssistantSuggestion[] {
    return currentProactiveSuggestions(this);
  }

  public maybeRefreshProactiveInBackground(): void {
    maybeRefreshProactiveInBackground(this);
  }

  public invalidateSourceControl(): void {
    invalidateSourceControl(this);
  }

  public signOutXiaomiAccount(): void {
    signOutXiaomiAccount(this);
  }

  public shouldKeepPopoverPinned(): boolean {
    return shouldKeepPopoverPinned(this);
  }

  public async performUndo(): Promise<void> {
    if (await rejectIfControlBlockedWhileLocked(this)) return;
    const paused = isUndoHoverPaused(this);
    if (!this.lastUndoAction || (!paused && this.lastUndoAction.expiresAtMs <= Date.now())) {
      clearUndoHoverPause(this);
      this.lastUndoAction = null;
      this.replyBanner = {
        text: t("没有可撤销的操作（仅支持 10 分钟内的操作撤销）"),
        source: t("撤销提示"),
      };
      this.render();
      return;
    }
    const action = this.lastUndoAction;
    this.lastUndoAction = null;
    clearUndoHoverPause(this);
    const sourceRevision = this.sourceRevision;
    const activeBatch = getRunningBatch(this, action);
    const ownerBatch =
      getUndoActionBatch(action) ??
      (activeBatch?.ownsUndoAction(action) ? activeBatch : null);
    if (ownerBatch && !ownerBatch.isFinished) {
      ownerBatch.stop("undo");
      await ownerBatch.waitForInFlight();
      if (sourceRevision !== this.sourceRevision) return;
    }
    const takenOverDevices = new Set<string>();
    const stepsToRestore = action.steps.filter((step) => {
      if (ownerBatch && !ownerBatch.ownsDeviceWrite(this, step.deviceId)) {
        takenOverDevices.add(step.deviceId);
        return false;
      }
      return true;
    });
    if (stepsToRestore.length === 0 && action.steps.length > 0) return;
    const failedSteps: UndoStep[] = [];
    const blockedDevices = new Set<string>();
    let failureMessage = "";
    for (const step of stepsToRestore) {
      if (ownerBatch && !ownerBatch.ownsDeviceWrite(this, step.deviceId)) {
        takenOverDevices.add(step.deviceId);
        continue;
      }
      if (blockedDevices.has(step.deviceId)) {
        failedSteps.push(step);
        continue;
      }
      let failed = false;
      for (const command of step.commands) {
        if (sourceRevision !== this.sourceRevision) return;
        if (ownerBatch && !ownerBatch.ownsDeviceWrite(this, step.deviceId)) {
          takenOverDevices.add(step.deviceId);
          break;
        }
        const ok = ownerBatch
          ? await ownerBatch.applyRestoreCommand(this, step.deviceId, command)
          : await this.applyCommand(command);
        if (!ok) {
          failed = true;
          failureMessage = this.replyBanner?.text ?? t("设备未响应");
        }
      }
      if (takenOverDevices.has(step.deviceId)) continue;
      if (failed) {
        failedSteps.push(step);
        blockedDevices.add(step.deviceId);
      } else {
        const restoredDevice = this.devices.find((d) => d.id === step.deviceId);
        if (restoredDevice && (!ownerBatch || ownerBatch.ownsDeviceWrite(this, step.deviceId))) {
          restoreUndoKindSnapshot(action, restoredDevice);
        }
      }
    }
    if (sourceRevision !== this.sourceRevision) return;
    if (
      failedSteps.length === 0 &&
      takenOverDevices.size > 0 &&
      takenOverDevices.size === new Set(action.steps.map((s) => s.deviceId)).size
    ) {
      return;
    }
    let remainingReceipt = action.habitReceipt;
    if (action.habitReceipt) {
      const notRestoredDevices = new Set([...blockedDevices, ...takenOverDevices]);
      if (notRestoredDevices.size === 0) {
        this.unrecordHabits(action.habitReceipt);
        remainingReceipt = undefined;
      } else {
        const { succeeded } = partitionHabitReceipt(action.habitReceipt, notRestoredDevices);
        if (succeeded) {
          this.unrecordHabits(succeeded);
        }
        const { remaining } = partitionHabitReceipt(action.habitReceipt, blockedDevices);
        remainingReceipt = remaining ?? undefined;
      }
    }
    if (failedSteps.length > 0 && this.lastUndoAction === null) {
      const retryAction: UndoAction = { ...action, steps: failedSteps, habitReceipt: remainingReceipt };
      copyUndoKindSnapshots(action, retryAction);
      this.lastUndoAction = retryAction;
    }
    this.replyBanner = failedSteps.length > 0
      ? { text: t("撤销未完成，{count} 项待恢复。{message}", { count: failedSteps.length, message: failureMessage }), source: t("控制失败"), isError: true }
      : { text: t("已撤销：{summary}", { summary: action.summary }), source: t("已恢复") };
    this.render();
  }

  public get applyCommand(): (command: DeviceCommand, readBackPower?: boolean) => Promise<boolean> {
    return getHostApplyCommand(this);
  }

  public set applyCommand(fn: (command: DeviceCommand, readBackPower?: boolean) => Promise<boolean>) {
    setCustomApplyCommand(this, fn);
  }

  /** Arms a high-risk confirmation and its own expiry timer, replacing any previous arm. */
  public setPendingHighRisk(pending: PendingHighRiskConfirmation): void {
    this.clearPendingHighRisk();
    this.pendingHighRisk = pending;
    this.pendingHighRiskTimer = window.setTimeout(() => {
      this.pendingHighRiskTimer = null;
      if (!this.pendingHighRisk) return;
      this.pendingHighRisk = null;
      // A gesture in progress (a slider drag) owns the current DOM; drop the row once it ends.
      this.queueBackgroundRender();
    }, Math.max(0, pending.expiresAtMs - Date.now()));
  }

  /** Disarms the arm and cancels its timer; callers render when the row must disappear now. */
  public clearPendingHighRisk(): void {
    if (this.pendingHighRiskTimer !== null) {
      window.clearTimeout(this.pendingHighRiskTimer);
      this.pendingHighRiskTimer = null;
    }
    this.pendingHighRisk = null;
  }


  public markCloudValuesStale(): void {
    markCloudValuesStale(this);
  }

  public markCloudValuesFresh(): void {
    markCloudValuesFresh(this);
  }

  public get valuesAreStale(): boolean {
    if (this.settings.connectionMode === "xiaomiCloud") {
      return this.cloudValuesStale && this.devices.length > 0;
    }
    if (this.settings.connectionMode === "homeAssistant") {
      return haConnectionBlock(this.settings.haBaseURL, this.haConnectionError ?? "") === "stale"
        && this.devices.length > 0;
    }
    return false;
  }

  public toggleVoiceInput(): void {
    toggleVoiceInput(this);
  }

  public async startXiaomiQRLogin(): Promise<void> {
    if (this.isPollingQR) return;
    const sourceRevAtStart = this.sourceRevision;
    this.isPollingQR = true;
    this.qrStatusText = t("正在获取小米安全登录二维码...");
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();

    try {
      const login = new MiAccountLogin(this.transport, this.settings.miCloudRegion);
      const ticket = await login.start();
      if (this.sourceRevision !== sourceRevAtStart) return;
      this.qrTicket = ticket;
      this.qrStatusText = t("请打开手机「米家 App → 我的 → 右上角扫一扫」确认登录");
      this.render();

      const session = await login.waitForScan(ticket);
      if (this.sourceRevision !== sourceRevAtStart) return;
      this.invalidateSourceControl();
      // The account-level passToken is never persisted (#27).
      this.settings.miSession = sessionWithoutPassToken(session);
      this.miSessionExpired = false;
      this.settings.miCloudRegion = normalizeMiCloudRegion(session.region);
      this.settings.connectionMode = "xiaomiCloud";
      this.settings.hasCompletedOnboarding = true;
      // Clear fake demo devices immediately upon real Xiaomi login
      this.devices = [];
      this.scenes = [];
      this.groupOwnerByMemberDid = new Map();
      this.selectRoom(null);
      this.activeSheet = "none";
      this.qrTicket = null;
      this.saveSettings();

      this.qrStatusText = t("已连接小米账号 {user}", { user: maskedMiUserId(session.userId) });
      this.replyBanner = {
        text: t("已登录小米账号 {user}，正在拉取真实设备...", { user: maskedMiUserId(session.userId) }),
        source: t("扫码成功"),
      };
      this.render();

      await this.refreshDevices(false);
    } catch (err) {
      if (this.sourceRevision === sourceRevAtStart) {
        const msg = err instanceof Error ? err.message : String(err);
        this.qrStatusText = t("扫码未完成：{message}", { message: msg });
      }
    } finally {
      if (this.sourceRevision === sourceRevAtStart) {
        this.isPollingQR = false;
        invokeTauriVoid("set_pin_popover", { pin: this.shouldKeepPopoverPinned() });
        this.render();
      }
    }
  }

  public formatRemainingMs(ms: number): string {
    const secs = Math.max(0, Math.ceil(ms / 1000));
    if (secs >= 60) {
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return s > 0 ? t("{m}分{s}秒", { m, s }) : t("{m}分钟", { m });
    }
    return t("{secs}秒", { secs });
  }

  /** How long the 撤销 control stays up. Matches macOS `undoBannerSeconds`: 10s, or 15s from three devices. */
  public syncUndoBannerClock(now = Date.now()): void {
    syncUndoBannerClock(this, now);
  }

  public undoButtonVisible(now = Date.now()): boolean {
    return undoButtonVisible(this, now);
  }

  public panelHealth(): PanelHealth {
    const mode = this.settings.connectionMode;
    if (mode === "demo") {
      return { kind: "demo", dot: "is-demo", label: t("演示模式") };
    }
    if (
      mode === "xiaomiCloud" &&
      this.settings.miSession &&
      (this.miSessionExpired || miSessionExpiryState(this.settings.miSession).kind === "expired")
    ) {
      return { kind: "offline", dot: "is-offline", label: t("米家登录已过期 · 点此扫码"), recovery: "qr" };
    }
    if (mode === "homeAssistant") {
      const block = haConnectionBlock(this.settings.haBaseURL, this.haConnectionError ?? "");
      if (block === "plaintext") {
        return { kind: "offline", dot: "is-offline", label: t("Home Assistant 未连接（已拒绝明文）"), recovery: "none" };
      }
      if (block === "auth") {
        return { kind: "offline", dot: "is-offline", label: t("Home Assistant 认证被拒绝"), recovery: "none" };
      }
    }
    if (this.sourceIsMissing()) {
      const recovery = mode === "xiaomiCloud" ? "qr" : "none";
      return { kind: "offline", dot: "is-offline", label: t("未配置数据源"), recovery };
    }
    const label = this.connectionFooterLabel();
    if (this.isSyncingCloud) {
      return { kind: "syncing", dot: "is-syncing", label };
    }
    const cloudFailed = mode === "xiaomiCloud" && this.cloudValuesStale;
    const haFailed = mode === "homeAssistant" && this.haConnectionError !== null;
    if (cloudFailed || haFailed || this.valuesAreStale) {
      const stale = this.valuesAreStale ? `${label} · ${t("可能过期")}` : label;
      return { kind: "degraded", dot: "is-degraded", label: stale };
    }
    return { kind: "online", dot: "is-online", label };
  }

  private connectionFooterLabel(): string {
    if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
      return t("米家账号 {user} · {count} 台设备", {
        user: maskedMiUserId(this.settings.miSession.userId),
        count: this.devices.length,
      });
    }
    if (this.settings.connectionMode === "homeAssistant") {
      return `Home Assistant · ${this.devices.length}`;
    }
    return t("演示模式");
  }

  private sourceIsMissing(): boolean {
    const mode = this.settings.connectionMode;
    if (mode === "xiaomiCloud") return this.settings.miSession === null;
    if (mode === "homeAssistant") {
      return this.settings.haBaseURL.trim() === "" || this.settings.haToken.trim() === "";
    }
    return false;
  }

  /** The native endpoint dialog rejected a public Home Assistant address. Keep it on the connection, not only the banner. */
  public noteServiceEndpointFailure(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    this.replyBanner = {
      text: message,
      source: t("服务地址未生效"),
      isError: true,
    };
    if (
      this.settings.connectionMode === "homeAssistant" &&
      haConnectionBlock(this.settings.haBaseURL, message) === "plaintext"
    ) {
      this.haConnectionError = message;
    }
    this.render();
  }

  public get statusSummaryText(): string {
    if (this.valuesAreStale) return t("可能过期");
    if (this.settings.connectionMode === "homeAssistant") return this.isSyncingCloud ? "Home Assistant · Connecting" : `Home Assistant · ${this.onlineDeviceCount} online`;
    if (this.settings.connectionMode === "xiaomiCloud") {
      if (this.isSyncingCloud && this.devices.length === 0) {
        return t("正在从小米云端同步真实设备...");
      }
      if (this.activeDeviceCount > 0) {
        return t("{count} 台开启中 · 共 {online} 台在线", { count: this.activeDeviceCount, online: this.onlineDeviceCount });
      }
      return t("全屋待机 · {online} 台实时在线", { online: this.onlineDeviceCount });
    }
    return t("演示预览 · 点击下方「扫码直连」同步你的真机");
  }

  public get effectiveAppearance(): "light" | "dark" {
    const prefersLight =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-color-scheme: light)").matches;
    return resolveAppearance(this.settings.appearance, prefersLight);
  }

  public get layout(): LayoutPrefs {
    return this.settings.layout;
  }

  /** Card sizes are per page: "all" or a room name. */
  public get pageKey(): string {
    return this.selectedRoom === "全部" ? "all" : this.selectedRoom;
  }

  public tileSize(dev: SmartDevice): Exclude<TileSize, "auto"> {
    return resolvedSize(chosenSize(this.layout, this.pageKey, dev.id), dev, this.settings.isCompactGridMode, this.settings.climatePanel);
  }

  public saveLayout(): void {
    this.saveSettings();
  }

  /**
   * Re-renders while keeping scroll offsets, and slides every card from its old position to its
   * new one (FLIP), so reorders, resizes and group moves animate instead of jumping.
   */
  public render(): void {
    if (this.panelSearch.isComposing) {
      if (this.activeSheet !== "none" ||
          document.activeElement?.id !== "command-input" || this.panelSearch.compositionSourceRevision !== this.sourceRevision) {
        this.panelSearch.isComposing = false;
      } else {
        this.pendingCloudRender = true;
        return;
      }
    }
    const focused = document.activeElement as HTMLElement | null;
    const focusedInput =
      focused && (focused.tagName === "INPUT" || focused.tagName === "TEXTAREA")
        ? (focused as HTMLInputElement | HTMLTextAreaElement)
        : null;
    const keepsFocusedDraft = focusedInput ? inputKeepsDraft(focusedInput) : false;
    const focusAttributes = focused
      ? Array.from(focused.attributes)
          .filter((attr) => attr.name === "id" || attr.name.startsWith("data-"))
          .map((attr) => ({ name: attr.name, value: attr.value }))
      : [];
    const focusSnapshot =
      focused && focusAttributes.length > 0
        ? {
            tagName: focused.tagName,
            attributes: focusAttributes,
            value: keepsFocusedDraft ? focusedInput?.value ?? null : null,
            selectionStart: keepsFocusedDraft ? focusedInput?.selectionStart ?? null : null,
            selectionEnd: keepsFocusedDraft ? focusedInput?.selectionEnd ?? null : null,
          }
        : null;
    const prevSubpageId = this.root.querySelector<HTMLElement>(".cc-tile.is-subpage")?.dataset.tileId ?? null;
    const prevSheetKey = activeSheetKey(this.root);
    const prevMenuKey = activeMenuKey(this.root);
    const tiles = Array.from(this.root.querySelectorAll<HTMLElement>("[data-tile-id]"));
    const before = new Map<string, DOMRect>();
    for (const el of tiles) {
      const rect = el.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 && el.dataset.tileId) {
        before.set(el.dataset.tileId, rect);
      }
    }
    const scrollTop = this.root.querySelector(".cc-scroll-area")?.scrollTop ?? 0;
    const roomLeft = this.root.querySelector(".cc-room-scroll")?.scrollLeft ?? 0;
    // The settings sheet scrolls its middle body, so that is the node whose offset has to survive.
    const sheetScroll = this.root.querySelector<HTMLElement>(".cc-sheet-body") ?? this.root.querySelector<HTMLElement>(".cc-sheet");
    const sheetScrollTop = sheetScroll?.scrollTop ?? 0;
    // 完成并保存 reads every field, so a live refresh must not discard typed text in the sheet (#78).
    const settingsDraft = captureSettingsDraft(this.root);

    this.pendingCloudRender = false;
    this.renderNow();
    syncPanelSelection(this);

    const nextSubpageEl = this.root.querySelector<HTMLElement>(".cc-tile.is-subpage");
    const nextSubpageId = nextSubpageEl?.dataset.tileId ?? null;
    const area = this.root.querySelector(".cc-scroll-area");
    if (area) {
      if (prevSubpageId === null && nextSubpageId !== null) {
        this.savedGridScrollTop = scrollTop;
        area.scrollTop = 0;
      } else if (prevSubpageId !== null && nextSubpageId === null) {
        area.scrollTop = this.savedGridScrollTop;
      } else if (prevSubpageId !== nextSubpageId) {
        area.scrollTop = 0;
      } else {
        area.scrollTop = scrollTop;
      }
    }
    const strip = this.root.querySelector<HTMLElement>(".cc-room-scroll");
    if (strip) strip.scrollLeft = roomLeft;
    const sheet = this.root.querySelector<HTMLElement>(".cc-sheet-body") ?? this.root.querySelector<HTMLElement>(".cc-sheet");
    if (sheet) sheet.scrollTop = sheetScrollTop;
    // A preset click mutates the fields without a render, so only a rebuild can have dropped a draft.
    if (
      restoreSettingsDraft(this.root, settingsDraft, (el, url) => this.syncKeyFieldWithEndpoint(el, url))
    ) {
      refreshHabitSharePreview(this);
    }

    if (focusSnapshot) {
      const matches = Array.from(
        this.root.querySelectorAll<HTMLElement>(focusSnapshot.tagName.toLowerCase()),
      ).filter((element) =>
        focusSnapshot.attributes.every(
          (attribute) => element.getAttribute(attribute.name) === attribute.value,
        ),
      );
      const replacement = matches.length === 1 ? matches[0] : undefined;
      if (replacement) {
        if (focusSnapshot.value !== null && "value" in replacement) {
          (replacement as HTMLInputElement).value = focusSnapshot.value;
        }
        replacement.focus({ preventScroll: true });
        if (
          focusSnapshot.selectionStart !== null &&
          "setSelectionRange" in replacement
        ) {
          (replacement as HTMLInputElement).setSelectionRange(
            focusSnapshot.selectionStart,
            focusSnapshot.selectionEnd ?? focusSnapshot.selectionStart,
          );
        }
      }
    }

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const nextSheet = visibleTopSheet(this.root);
    const nextSheetKey = activeSheetKey(this.root);
    const nextMenu = this.root.querySelector<HTMLElement>(".cc-menu");
    const nextMenuKey = activeMenuKey(this.root);
    if (!reduce) {
      if (nextSheet && nextSheetKey !== null && nextSheetKey !== prevSheetKey) {
        nextSheet.animate?.(
          [{ transform: "translateY(10px)" }, { transform: "translateY(0)" }],
          { duration: 180, easing: "cubic-bezier(0, 0, 0, 1)" },
        );
      }
      if (nextMenu && nextMenuKey !== null && nextMenuKey !== prevMenuKey) {
        nextMenu.animate?.(
          [{ transform: "translateY(-4px)" }, { transform: "translateY(0)" }],
          { duration: 120, easing: "cubic-bezier(0, 0, 0, 1)" },
        );
      }
      if (nextSubpageEl && nextSubpageId !== null && nextSubpageId !== prevSubpageId) {
        nextSubpageEl.animate?.(
          [{ opacity: 0.75, transform: "translateX(16px)" }, { opacity: 1, transform: "translateX(0)" }],
          { duration: 240, easing: "cubic-bezier(0, 0, 0, 1)" },
        );
      } else if (prevSubpageId !== null && nextSubpageId === null) {
        this.root.querySelector<HTMLElement>(".cc-scroll-area")?.animate?.(
          [{ opacity: 0.75, transform: "translateX(-12px)" }, { opacity: 1, transform: "translateX(0)" }],
          { duration: 200, easing: "cubic-bezier(0, 0, 0, 1)" },
        );
      } else if (prevSubpageId === null && nextSubpageId === null && before.size > 0) {
        this.root.querySelectorAll<HTMLElement>("[data-tile-id]").forEach((el) => {
          const id = el.dataset.tileId as string;
          const old = before.get(id);
          if (!old || id === this.draggingId) return;
          const now = el.getBoundingClientRect();
          if (now.width === 0 || now.height === 0) return;
          const dx = old.left - now.left;
          const dy = old.top - now.top;
          if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
          el.animate?.(
            [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "translate(0, 0)" }],
            { duration: 240, easing: "cubic-bezier(0, 0, 0, 1)" },
          );
        });
      }
    }
    this.applyDragOffset();
    this.animateEntrance = false;
    this.poppedDeviceId = null;
  }

  private renderNow(): void {
    renderPanel(this);
  }

  public renderEnvironmentStrip(): string {
    return renderEnvironmentStripView({
      readings: this.computedEnvironmentReadings,
      watts: this.totalPowerWatts,
      valuesAreStale: this.valuesAreStale,
      escapeHtml: (v) => this.escapeHtml(v),
    });
  }

  public renderDeviceGrid(): string {
    pruneUnsupportedLightEffectsOnHost(this);
    if (normalizeSearch(this.panelSearch.query)) {
      const results = withAliases(this.layout, this.presentationDevices);
      return results.length
        ? `<div id="panel-search-results" class="cc-devices-grid is-flow">${results.map((device, index) => this.renderDeviceTile(device, this.settings.isCompactGridMode && this.expandedDeviceId !== device.id ? 3 : 6, index)).join("")}</div>`
        : `<div id="panel-search-results" class="cc-empty-state"><div class="cc-empty-title">${t("没有匹配的设备")}</div><div class="cc-empty-subtitle">${t("输入设备名、房间或拼音首字母；整句话按回车执行")}</div></div>`;
    }
    if (this.settings.connectionMode === "homeAssistant" && this.devices.length === 0) return `<div class="cc-empty-state"><div class="cc-empty-title">Home Assistant</div><div class="cc-empty-subtitle">${this.isSyncingCloud ? "Connecting…" : "No connected devices. Check the saved URL, token and endpoint permission."}</div><button class="cc-btn-secondary" id="btn-empty-settings">Settings</button></div>`;
    // A selected home the cloud no longer returns devices for is not an empty account (#67):
    // other homes still have devices, so offer the way back to all of them.
    if (
      this.settings.selectedHomeId !== null &&
      this.devices.length === 0 &&
      this.homes.some((home) => home.deviceCount > 0)
    ) {
      return `
        <div class="cc-empty-state" id="empty-selected-home">
          <div class="cc-empty-icon">${SF_ICONS.houseFill}</div>
          <div class="cc-empty-title">${t("当前所选家庭暂无可显示的设备")}</div>
          <div class="cc-empty-actions">
            <button class="cc-btn-primary" id="btn-empty-all-homes">${t("显示全部家庭")}</button>
          </div>
        </div>
      `;
    }
    if (this.settings.connectionMode === "xiaomiCloud" && this.devices.length === 0) {
      if (this.isSyncingCloud) {
        return `
          <div class="cc-empty-state">
            <div class="cc-empty-icon is-pulsing">${SF_ICONS.sparkles}</div>
            <div class="cc-empty-title">${t("正在同步你的真实米家设备…")}</div>
            <div class="cc-empty-subtitle">${t("正在从小米云端拉取房间、MIoT 规格与实时状态")}</div>
          </div>
        `;
      }
      return `
        <div class="cc-empty-state">
          <div class="cc-empty-icon">${SF_ICONS.houseFill}</div>
          <div class="cc-empty-title">${t("尚未同步到米家设备")}</div>
          <div class="cc-empty-subtitle">${this.escapeHtml(t("当前地区（{region}）没有设备，可尝试切换地区", { region: normalizeMiCloudRegion(this.settings.miSession?.region ?? this.settings.miCloudRegion) }))}</div>
          <div class="cc-empty-actions">
            <button class="cc-btn-primary" id="btn-empty-resync">${t("重新同步设备")}</button>
            <button class="cc-btn-secondary" id="btn-empty-settings">${t("切换账号 / 设置")}</button>
          </div>
        </div>
      `;
    }

    if (this.devices.length > 0 && this.presentationDevices.length === 0 && (this.settings.hideOfflineDevices || this.listCut.kind === "deviceKind")) {
      const title = this.listCut.kind === "deviceKind"
        ? (this.settings.hideOfflineDevices ? t("这一类暂无通电在线的设备") : t("这一类暂无设备"))
        : t("该房间暂无通电在线的设备");
      const offlineButton = this.settings.hideOfflineDevices
        ? `<div class="cc-empty-actions"><button class="cc-btn-secondary" id="btn-show-offline">${t("显示离线设备")}</button></div>`
        : "";
      return `
        <div class="cc-empty-state">
          <div class="cc-empty-title">${title}</div>
          ${offlineButton}
        </div>
      `;
    }

    const isAll = this.selectedRoom === "全部";
    const ordered = withAliases(this.layout, applyOrder(this.layout.order, this.presentationDevices));
    const sections = pageSections(this.layout, ordered, isAll);
    let index = 0;
    return sections
      .map((section) => {
        const collapsed = this.layout.collapsed.includes(scopedKey(this.pageKey, section.id));
        const hasActiveSubpage =
          this.expandedDeviceId !== null && section.devices.some((d) => d.id === this.expandedDeviceId);
        const spanMap = spans(section.devices, (d) => (this.expandedDeviceId === d.id ? "full" : this.tileSize(d)));
        const header =
          section.title === null
            ? ""
            : `<button class="cc-group-header ${collapsed ? "is-collapsed" : ""}" data-collapse="${this.escapeHtml(section.id)}" ${section.groupId ? `data-group-id="${this.escapeHtml(section.groupId)}"` : ""}>
                <span class="cc-group-caret">${SF_ICONS.chevronDown}</span>
                <span class="cc-group-title">${this.escapeHtml(section.title)}</span>
                <span class="cc-group-count">${section.devices.length}</span>
                <span class="cc-group-rule"></span>
              </button>`;
        const body = collapsed && !hasActiveSubpage
          ? ""
          : `<div class="cc-devices-grid is-flow">
              ${section.devices.map((dev) => this.renderDeviceTile(dev, spanMap.get(dev.id) ?? 6, index++)).join("")}
            </div>`;
        return `<section class="cc-group">${header}${body}</section>`;
      })
      .join("");
  }

  public renderDeviceTile(dev: SmartDevice, span: number, index: number): string {
    return renderDeviceTileView(dev, {
      span,
      index,
      size: this.tileSize(dev),
      animateEntrance: this.animateEntrance,
      poppedDeviceId: this.poppedDeviceId,
      draggingId: this.draggingId,
      isEditingLayout: this.isEditingLayout,
      selectedRoom: this.selectedRoom,
      valuesAreStale: this.valuesAreStale,
      expandedDeviceId: this.expandedDeviceId,
      pendingHighRisk: this.pendingHighRisk,
      waitingDeviceIds: this.waitingDeviceIds,
      dimPreview: this.dimPreview,
      deviceFacets: this.deviceFacets,
      allowAdvancedFacetWrites: this.settings.allowAdvancedFacetWrites,
      isPinned: isDevicePinned(dev.id, this.layout),
      unsupportedLightEffects: getUnsupportedLightEffects(this, dev.id),
      speakerDrawerState: getSpeakerDrawerItemState(this, dev.id),
      escapeHtml: (v) => this.escapeHtml(v),
    });
  }

  public renderHomeMenu(): string {
    return renderHomeMenu(this);
  }

  public renderContextMenu(): string {
    return renderContextMenu(this);
  }

  public renderPrompt(): string {
    return renderUrlConfirmationPrompt(this) || renderPrompt(this);
  }

  public renderOnboardingModal(): string {
    return renderOnboardingModal(this);
  }

  public renderSettingsModal(): string {
    return renderSettingsModal(this);
  }

  public bindEvents(): void {
    bindEventsImpl(this);
    bindPersistentUndoEvents(this);
  }

  public bindDeckEvents(): void {
    bindDeckEvents(this);
  }

  public startEditing(): void {
    this.isEditingLayout = true;
    this.expandedDeviceId = null;
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();
  }

  public stopEditing(): void {
    this.isEditingLayout = false;
    this.draggingId = null;
    this.dragPointer = null;
    invokeTauriVoid("set_pin_popover", { pin: this.shouldKeepPopoverPinned() });
    this.render();
  }

  public openPrompt(prompt: NonNullable<typeof this.prompt>): void {
    this.ctxMenu = null;
    this.prompt = prompt;
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();
  }

  public closePrompt(): void {
    this.prompt = null;
    invokeTauriVoid("set_pin_popover", { pin: this.shouldKeepPopoverPinned() });
    this.render();
  }

  public savePrompt(raw: string): void {
    const name = raw.trim();
    const p = this.prompt;
    if (!p || p.kind === "roomOrderEditor") return;
    if (p.kind === "newGroup") {
      if (!name) return;
      const id = `g${Date.now().toString(36)}`;
      this.layout.groups.push({ id, name });
      this.layout.groupMap[p.deviceId] = id;
    } else if (p.kind === "renameGroup") {
      if (!name) return;
      this.layout.groups = this.layout.groups.map((g) => (g.id === p.groupId ? { id: g.id, name } : g));
    } else {
      const original = this.devices.find((d) => d.id === p.deviceId)?.name;
      if (!name || name === original) delete this.layout.aliases[p.deviceId];
      else this.layout.aliases[p.deviceId] = name;
    }
    this.saveLayout();
    this.closePrompt();
  }

  /** Keeps the picked-up card under the pointer; runs after every render. */
  public applyDragOffset(): void {
    if (!this.draggingId || !this.dragPointer) return;
    const el = this.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(this.draggingId)}"]`);
    if (!el) return;
    el.style.translate = "0px 0px";
    const r = el.getBoundingClientRect();
    const p = this.dragPointer;
    el.style.translate = `${p.x - p.grabX - r.left}px ${p.y - p.grabY - r.top}px`;
  }

  /** Section of a device on the current page: "pinned", a user group id, or "rest". */
  private sectionOf(id: string): string {
    if (this.selectedRoom === "全部" && isDevicePinned(id, this.layout)) return "pinned";
    const g = this.layout.groupMap[id];
    return g && this.layout.groups.some((x) => x.id === g) ? g : "rest";
  }

  /** Before/after the hovered card (top or left half = before); first when above every card. */
  public swapIfNeeded(x: number, y: number): void {
    const dragged = this.draggingId;
    if (!dragged) return;
    const now = performance.now();
    if (this.lastSwap && now - this.lastSwap.at < 250) return;
    const others = Array.from(this.root.querySelectorAll<HTMLElement>("[data-tile-id]"))
      .filter((el) => el.dataset.tileId !== dragged)
      .map((el) => ({ id: el.dataset.tileId as string, r: el.getBoundingClientRect() }));
    if (others.length === 0) return;
    let target: string | null = null;
    let after = false;
    const top = others.reduce((a, b) => (b.r.top < a.r.top ? b : a));
    if (y < top.r.top) {
      target = top.id;
    } else {
      const hit = others.find((o) => x >= o.r.left && x <= o.r.right && y >= o.r.top && y <= o.r.bottom);
      if (!hit) return;
      target = hit.id;
      const r = hit.r;
      after = y < r.top + r.height * 0.3 ? false : y > r.bottom - r.height * 0.3 ? true : x > r.left + r.width / 2;
    }
    const slot = `${target}|${after}`;
    if (this.lastSwap?.slot === slot) return;
    this.lastSwap = { slot, at: now };
    const to = this.sectionOf(target);
    const from = this.sectionOf(dragged);
    if (to !== from && to !== "pinned" && from !== "pinned") {
      if (to === "rest") delete this.layout.groupMap[dragged]; else this.layout.groupMap[dragged] = to;
    }
    this.layout.order = moveInOrder(this.layout.order, this.devices.map((d) => d.id), dragged, target, after);
    this.saveLayout();
    this.render();
  }

  /**
   * One pointer stream drives tap, long-press-to-edit, drag-to-reorder and drag-to-dim. Listeners
   * live on the persistent root/window, so re-rendering mid-gesture never cancels the drag.
   */
  public bindSettingsEvents(): void {
    bindSettingsEvents(this);
  }

  private bindLayoutGestures(): void {
    bindLayoutGestures(this);
  }

  /**
   * The panel has no title bar, so empty header space doubles as the move handle: the press goes to
   * the OS move loop and the backend snaps the window to the nearest work-area corner (#204). Buttons
   * and fields keep their own clicks.
   */
  private bindPanelDrag(): void {
    this.root.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !window.__TAURI_INTERNALS__?.invoke) return;
      const target = event.target;
      if (!(target instanceof window.HTMLElement)) return;
      if (!target.closest(".cc-header-top")) return;
      if (target.closest("button, input, textarea, select, a")) return;
      invokeTauriVoid("start_panel_drag");
    });
  }

  /**
   * Windows 11 native taskbar flyout choreography:
   * - Present (`menumijia:panel-present`): 250ms `cubic-bezier(0, 0, 0, 1)` decelerate slide out
   *   from the docked taskbar edge (`bottom` / `top` / `left` / `right`), clearing transform at rest.
   * - Dismiss (`menumijia:panel-dismiss`): 167ms `cubic-bezier(1, 0, 1, 1)` accelerate slide back
   *   into the taskbar edge, then `finish_hide_panel({ seq })` hides the HWND without bounce or flash.
   */
  private bindOpenAnimation(): void {
    const ownerWin = this.root.ownerDocument?.defaultView ?? window;
    let openClearTimer: number | null = null;
    let dismissTimer: number | null = null;
    let activeDismissSeq: number | null = null;

    const normalizeEdge = (raw: unknown): "bottom" | "top" | "left" | "right" =>
      raw === "top" || raw === "left" || raw === "right" ? raw : "bottom";

    const prefersReducedMotion = (): boolean =>
      typeof ownerWin.matchMedia === "function" &&
      ownerWin.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const clearOpenTimer = (): void => {
      if (openClearTimer !== null) {
        ownerWin.clearTimeout(openClearTimer);
        openClearTimer = null;
      }
    };

    const clearDismissTimer = (): void => {
      if (dismissTimer !== null) {
        ownerWin.clearTimeout(dismissTimer);
        dismissTimer = null;
      }
      activeDismissSeq = null;
    };

    const scrollActiveRoomIntoView = (): void => {
      const strip = this.root.querySelector<HTMLElement>(".cc-room-scroll");
      const active = strip?.querySelector<HTMLElement>(".cc-room-pill.is-active");
      if (strip && active) {
        strip.scrollLeft =
          this.listCut.kind === "all"
            ? 0
            : active.offsetLeft - (strip.clientWidth - active.offsetWidth) / 2;
      }
    };

    let hasExplicitPresent = false;

    const playPresent = (edge?: unknown): void => {
      clearDismissTimer();
      clearOpenTimer();
      this.root.dataset.flyoutEdge = normalizeEdge(edge ?? this.root.dataset.flyoutEdge);
      this.root.classList.remove("is-parked", "is-closing");
      this.applyPanelHeight();
      this.syncPanelPlacement();
      scrollActiveRoomIntoView();
      if (prefersReducedMotion()) {
        this.root.classList.remove("is-opening");
        return;
      }
      this.root.classList.remove("is-opening");
      void this.root.offsetWidth;
      this.root.classList.add("is-opening");
      openClearTimer = ownerWin.setTimeout(() => {
        openClearTimer = null;
        this.root.classList.remove("is-opening");
      }, 275);
    };
    const finishDismiss = (seq: number): void => {
      if (activeDismissSeq !== seq) return;
      clearDismissTimer();
      this.root.classList.remove("is-closing");
      if (window.__TAURI_INTERNALS__?.invoke) {
        this.root.classList.add("is-parked");
      }
      invokeTauriVoid("finish_hide_panel", { seq });
    };

    const playDismiss = (seq: number, edge?: unknown): void => {
      clearOpenTimer();
      clearDismissTimer();
      this.root.dataset.flyoutEdge = normalizeEdge(edge ?? this.root.dataset.flyoutEdge);
      this.root.classList.remove("is-parked", "is-opening");
      activeDismissSeq = seq;
      if (prefersReducedMotion()) {
        this.root.classList.remove("is-closing");
        finishDismiss(seq);
        return;
      }
      this.root.classList.remove("is-closing");
      void this.root.offsetWidth;
      this.root.classList.add("is-closing");
      dismissTimer = ownerWin.setTimeout(() => {
        finishDismiss(seq);
      }, 185);
    };

    const onPanelPresent = (event: Event) => {
      if (!this.root.isConnected) return;
      hasExplicitPresent = true;
      const detail = (event as CustomEvent<{ edge?: unknown } | undefined>).detail;
      playPresent(detail?.edge);
    };
    const onPanelDismiss = (event: Event) => {
      if (!this.root.isConnected) return;
      const detail = (event as CustomEvent<{ seq?: unknown; edge?: unknown } | undefined>).detail;
      const seq = typeof detail?.seq === "number" ? detail.seq : 0;
      playDismiss(seq, detail?.edge);
    };
    const onInteractiveClick = () => {
      if (this.root.classList.contains("is-opening")) {
        clearOpenTimer();
        this.root.classList.remove("is-opening");
      }
    };
    ownerWin.addEventListener("menumijia:panel-present", onPanelPresent);
    ownerWin.addEventListener("menumijia:panel-dismiss", onPanelDismiss);
    this.root.addEventListener("click", onInteractiveClick, true);
    this.appDisposers.push(
      () => ownerWin.removeEventListener("menumijia:panel-present", onPanelPresent),
      () => ownerWin.removeEventListener("menumijia:panel-dismiss", onPanelDismiss),
      () => this.root.removeEventListener("click", onInteractiveClick, true),
      () => clearOpenTimer(),
      () => clearDismissTimer(),
    );

    this.root.addEventListener("animationend", (e) => {
      const target = e.target as HTMLElement | null;
      if (target === this.root || target?.classList?.contains("cc-popover")) {
        if (this.root.classList.contains("is-opening")) {
          clearOpenTimer();
          this.root.classList.remove("is-opening");
        } else if (this.root.classList.contains("is-closing") && activeDismissSeq !== null) {
          finishDismiss(activeDismissSeq);
        }
      }
    });

    if (typeof ownerWin.matchMedia === "function") {
      const mql = ownerWin.matchMedia("(prefers-color-scheme: light)");
      const onSchemeChange = () => {
        if (this.settings.appearance === "system" && this.root.isConnected) {
          this.render();
        }
      };
      mql.addEventListener?.("change", onSchemeChange);
      this.appDisposers.push(() => mql.removeEventListener?.("change", onSchemeChange));
    }

    this.root.dataset.flyoutEdge = "bottom";
    playPresent("bottom");
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (invoke) {
      // Park the WebView2 swapchain at opacity 0 while the cold-launched HWND is hidden so the
      // first ShowWindow never flashes a resting frame before menumijia:panel-present arrives.
      void invoke<boolean>("panel_is_visible")
        .then((visible) => {
          if (visible === false && !hasExplicitPresent && activeDismissSeq === null && this.root.isConnected) {
            clearOpenTimer();
            this.root.classList.remove("is-opening");
            this.root.classList.add("is-parked");
          }
        })
        .catch(() => undefined);
    }
  }

  /**
   * The native backdrop the window manager granted (§1.4). WebView2 cannot sample the desktop, so the
   * stylesheet only lowers the panel fill to a tint when Rust reports a real Acrylic/Mica backdrop.
   */
  public syncPanelBackdrop(): void {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    void invoke<string>("panel_backdrop")
      .then((value) => {
        this.root.dataset.backdrop = value === "acrylic" ? "acrylic" : "none";
      })
      .catch(() => undefined);
  }

  /** Pulls the placement the backend persists so a drag shows up in the settings sheet (#204). */
  public syncPanelPlacement(): void {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    const requested = this.panelAnchor;
    void invoke<PanelPlacement>("panel_placement")
      .then((value) => {
        // A choice made while this request was in flight wins; the next open re-reads the backend.
        if (this.panelAnchor !== requested) return;
        const { anchor } = parsePanelPlacement(value);
        if (anchor === this.panelAnchor) return;
        this.panelAnchor = anchor;
        if (this.activeSheet === "settings") this.render();
      })
      .catch(() => undefined);
  }

  public applyPanelHeight(): void {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    this.panelGeometryUpdates = this.panelGeometryUpdates.then(async () => {
      const h = PANEL_HEIGHTS.find((item) => item.id === this.settings.panelHeight) ?? PANEL_HEIGHTS[1]!;
      await invoke("set_panel_height", { height: h.px });
    }).catch((error: unknown) => console.error("Panel geometry update failed", error));
  }

  /** The saved API key, isolated per provider preset and bound to custom host (#19, §6). */
  public apiKeyFor(baseURL: string): string {
    const identity = assistantEndpointIdentity(baseURL);
    if (!identity) return "";
    const preset = inferAssistantPreset(baseURL);
    if (preset.id !== "custom") {
      const slotKey = this.assistantKeysByPreset[preset.id]?.trim() ?? "";
      if (slotKey) return slotKey;
    } else {
      const customEndpoint = this.settings.assistantCustomKeyEndpoint ?? this.settings.assistantKeyEndpoint;
      if (identity === customEndpoint) {
        const customKey = this.assistantKeysByPreset.custom?.trim() ?? "";
        if (customKey) return customKey;
      }
    }
    const key = this.settings.openRouterApiKey.trim();
    if (!key) return "";
    return identity === this.settings.assistantKeyEndpoint ? key : "";
  }

  private isKnownSavedKey(candidate: string): boolean {
    if (!candidate) return false;
    if (candidate === this.settings.openRouterApiKey.trim()) return true;
    return Object.values(this.assistantKeysByPreset).some((value) => value.trim() === candidate);
  }

  /** Pointing the address at another server loads its own slot or clears the previous provider's saved key. */
  public syncKeyFieldWithEndpoint(apiKeyEl: HTMLInputElement, baseURL: string): void {
    const targetKey = this.apiKeyFor(baseURL);
    const current = apiKeyEl.value.trim();
    if (targetKey !== "") {
      if (current === "" || this.isKnownSavedKey(current)) {
        apiKeyEl.value = targetKey;
      }
    } else if (this.isKnownSavedKey(current)) {
      apiKeyEl.value = "";
    }
  }

  public escapeHtml(str: string): string {
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
}

if (typeof document !== "undefined") {
  document.addEventListener("DOMContentLoaded", () => {
    const root = document.getElementById("app");
    if (root) {
      new MenuMijiaWindowsApp(root);
    }
  });
}
