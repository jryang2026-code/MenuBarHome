import { ManualControlPolicy } from "../core/assistant.js";
import { deviceCategory } from "../core/assistant/deviceCategory.js";
import { haConnectionScope } from "../core/haTransportGate.js";
import { tr3 } from "../core/i18n.js";
import { evaluateDeviceEntityWriteGate, isHaScopeEnabledInState, isMiSessionEnabledInState, miAccountScope } from "../core/miAccountControl.js";
import {
  captureMoodTargetForDevice, createMoodId, formatMoodCreatedAt,
  moodEntityIdForDevice, moodTargetFields, MOOD_SNAPSHOT_LIMIT, resolveMoodFieldCommand,
  saveMoodSnapshots, type MoodField, type MoodSnapshot, type MoodTarget,
} from "../core/moodSnapshot.js";
import type { DeviceCommand, SmartDevice } from "../core/models.js";
import {
  claimDeviceWrite, currentDeviceWriteClaim, lockOptimistic, ownsDeviceWrite, peekDeviceWriteSeq, registerUndoActionBatch,
  type DeviceWriteClaim, type OptimisticLockHost, type UndoActionBatch,
} from "../core/optimisticLock.js";
import { switchLightMarkIds } from "../core/switchLightMarks.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoAction, UndoStep } from "./appTypes.js";
import { buildHostCapabilityContext, getHostDualSourceState, isDualSourceEnabled, resolveHostMiSelectionState } from "./cloudRefresh.js";
import { coverPositionRequiresConfirmation } from "./detailDrawers.js";
import type { HotkeyExecutionOutcome } from "./hotkeyBindings.js";
import { withAliases } from "./panelPrefs.js";
import { recordUndoKindSnapshots, shouldKeepPopoverPinned } from "./speechGuard.js";
import { invokeTauriVoid, isWorkstationLockBlockingControl } from "./transport.js";

const ALL_ROOMS_ID = "__all_rooms__";

export interface PendingMoodCapturePrompt { readonly roomId: string; readonly name: string }
export interface PendingMoodConfirmationPrompt { readonly moodId: string; readonly moodName: string; readonly riskyDeviceNames: readonly string[]; readonly resolve: (approved: boolean) => void }

interface MoodStep {
  readonly target: MoodTarget; readonly deviceId: string; readonly deviceName: string;
  readonly command: DeviceCommand; readonly restore: readonly DeviceCommand[];
  readonly priorDevice: SmartDevice; readonly requiresConfirmation: boolean;
  readonly hazardProfileKey: string; readonly initialClaim: DeviceWriteClaim;
}

/**
 * Owns a finished mood's undo: each device's restore runs only while the mood (or this undo's own
 * restore) is still the newest write to it, so a device the user took over meanwhile is skipped.
 */
class MoodUndoBatch implements UndoActionBatch {
  public readonly isStopped = true;
  public readonly isFinished = true;
  public constructor(private readonly claims: Map<string, DeviceWriteClaim>) {}
  public stop(): void {}
  public async waitForInFlight(): Promise<void> {}
  public recordWriteClaim(deviceId: string, claim: DeviceWriteClaim): void { this.claims.set(deviceId, claim); }
  public ownsDeviceWrite(host: OptimisticLockHost, deviceId: string): boolean {
    const claim = this.claims.get(deviceId);
    return claim !== undefined && ownsDeviceWrite(host, claim);
  }
  public async applyRestoreCommand(
    host: OptimisticLockHost & { applyCommand(command: DeviceCommand, readBackPower?: boolean): Promise<boolean> },
    deviceId: string,
    command: DeviceCommand,
  ): Promise<boolean> {
    const seqBefore = peekDeviceWriteSeq(host, deviceId);
    const sendPromise = host.applyCommand(command);
    this.recordWriteClaim(deviceId, peekDeviceWriteSeq(host, deviceId) === seqBefore ? claimDeviceWrite(host, deviceId) : currentDeviceWriteClaim(host, deviceId));
    return sendPromise;
  }
}

const syncPin = (host: MenuMijiaWindowsApp): void => invokeTauriVoid("set_pin_popover", { pin: shouldKeepPopoverPinned(host) });

export function broadcastMoodSnapshotsSync(): void {
  if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") {
    const EventCtor = window.Event ?? Event;
    window.dispatchEvent(new EventCtor("menumijia:moods-sync"));
  }
}

export function dismissPendingMoodPrompts(host: MenuMijiaWindowsApp): void {
  const hadCapture = host.pendingMoodCapture !== null;
  const pending = host.pendingMoodConfirm;
  host.pendingMoodCapture = null;
  host.pendingMoodConfirm = null;
  pending?.resolve(false);
  if (hadCapture || pending) syncPin(host);
}

export function openMoodCapturePrompt(host: MenuMijiaWindowsApp): void {
  if (host.moodAvailableRooms().length === 0 && host.devices.length === 0) return;
  const roomId = host.activeRoomId !== null ? host.activeRoomId : (host.moodAvailableRooms()[0]?.id ?? ALL_ROOMS_ID);
  host.pendingMoodCapture = { roomId, name: "" };
  syncPin(host);
  host.render();
}

export function resolvePendingMoodConfirmation(host: MenuMijiaWindowsApp, approved: boolean): void {
  const pending = host.pendingMoodConfirm;
  if (!pending) return;
  host.pendingMoodConfirm = null;
  syncPin(host);
  pending.resolve(approved);
  host.render();
}

export function moodDeviceScope(host: MenuMijiaWindowsApp, device: SmartDevice): string | null {
  const route = isDualSourceEnabled(host) ? getHostDualSourceState(host)?.routes[device.id] : undefined;
  const backend = route?.backend ?? device.sourceBackend ?? host.settings.connectionMode;
  if (backend === "demo") return "demo";
  if (backend === "homeAssistant") return haConnectionScope(host.settings.haBaseURL, host.settings.haToken) ?? "ha:";
  if (device.accountId?.trim()) return miAccountScope(device.accountId);
  if (host.settings.miSession) return miAccountScope(`${host.settings.miSession.userId}@${host.settings.miSession.region}`);
  return host.settings.connectionMode === "xiaomiCloud" ? "mi:" : null;
}

function moodCapabilityAllowsDevice(host: MenuMijiaWindowsApp, device: SmartDevice): string | null {
  if (host.settings.connectionMode === "demo" && !isDualSourceEnabled(host)) return null;
  return evaluateDeviceEntityWriteGate({
    targetKind: "device",
    targetIdOrEntityId: moodEntityIdForDevice(device) ?? device.id,
    resolvedActiveDeviceId: device.id,
    context: buildHostCapabilityContext(host),
    rejectUnknown: false,
    languagePreference: host.settings.interfaceLanguage,
  });
}

function isMoodWriteBlockedByMiSession(host: MenuMijiaWindowsApp): boolean {
  if (!host.miSessionExpired || (host.settings.connectionMode === "demo" && !isDualSourceEnabled(host))) return false;
  const sel = resolveHostMiSelectionState(host);
  const haScope = haConnectionScope(host.settings.haBaseURL, host.settings.haToken);
  if (haScope !== null && isHaScopeEnabledInState(haScope, sel)) return false;
  if (host.settings.connectionMode === "xiaomiCloud") return true;
  return Boolean(isDualSourceEnabled(host) && host.settings.miSession && isMiSessionEnabledInState(host.settings.miSession, sel));
}

function moodHazardProfileKey(device: SmartDevice): string {
  const subtype = device.kind.kind === "cover" ? device.kind.subtype : "";
  const appMeta = device.kind.kind === "appliance" ? `${device.kind.heats}:${device.kind.startAction !== null}:${device.kind.targetTemperature ?? ""}` : "";
  const waterHeater = device.kind.kind === "climate" && device.name.includes("热水器");
  return `${device.kind.kind}|${deviceCategory(device)}|${subtype}|${appMeta}|${waterHeater}|${ManualControlPolicy.wallSwitchMayControlLight(device)}|${switchLightMarkIds().has(device.id)}`;
}

const reportedCoverPos = (host: MenuMijiaWindowsApp, dev: SmartDevice): number | null =>
  dev.kind.kind !== "cover" ? null : (host.lastCoverPositions[dev.id] ?? (dev.kind.motion === "stopped" ? dev.kind.positionPercent : null));

function buildStepForField(
  host: MenuMijiaWindowsApp, aliased: readonly SmartDevice[], live: SmartDevice, target: MoodTarget, field: MoodField,
): MoodStep | null {
  const coverPos = reportedCoverPos(host, live);
  const resolved = resolveMoodFieldCommand(field, live, coverPos);
  if (!resolved) return null;
  const requiresConfirmation = field.kind === "coverPosition" && live.kind.kind === "cover"
    ? coverPositionRequiresConfirmation(live.kind.subtype, coverPos, field.value)
    : resolved.intent !== null && ManualControlPolicy.requiresConfirmation(resolved.intent, aliased, undefined, moodEntityIdForDevice(live) ?? undefined);
  return {
    target, deviceId: live.id, deviceName: live.name, command: resolved.command, restore: resolved.restore,
    priorDevice: structuredClone(live), requiresConfirmation, hazardProfileKey: moodHazardProfileKey(live),
    initialClaim: currentDeviceWriteClaim(host, live.id),
  };
}

export function captureMoodForHost(host: MenuMijiaWindowsApp, rawName: string, roomId: string | null): boolean {
  const pref = host.settings.interfaceLanguage;
  const trimmed = rawName.trim();
  if (!trimmed) return false;
  const roomDevices = roomId === null || roomId === ALL_ROOMS_ID ? host.devices : host.devices.filter((d) => d.roomId === roomId);
  const targets: MoodTarget[] = [];
  for (const d of withAliases(host.layout, roomDevices)) {
    if (moodCapabilityAllowsDevice(host, d) !== null) continue;
    const t = captureMoodTargetForDevice(d, moodDeviceScope(host, d), { lastCoverPosition: host.lastCoverPositions[d.id] ?? null });
    if (t) targets.push(t);
  }
  if (targets.length === 0) {
    host.replyBanner = { text: tr3("这个房间没有可保存的设备状态", "這個房間沒有可儲存的裝置狀態", "No capturable device states in this room", undefined, pref), source: tr3("氛围", "氛圍", "Mood", undefined, pref), isError: true };
    host.render();
    return false;
  }
  const mood: MoodSnapshot = { id: createMoodId(), name: trimmed, createdAt: formatMoodCreatedAt(), targets };
  host.moods = saveMoodSnapshots([mood, ...host.moods].slice(0, MOOD_SNAPSHOT_LIMIT));
  host.pendingMoodCapture = null;
  broadcastMoodSnapshotsSync();
  host.replyBanner = { text: tr3("已保存氛围「{name}」（{count} 台设备）", "已儲存氛圍「{name}」（{count} 台裝置）", 'Saved mood "{name}" ({count} devices)', { name: trimmed, count: targets.length }, pref), source: tr3("氛围", "氛圍", "Mood", undefined, pref) };
  syncPin(host);
  host.render();
  return true;
}

export function deleteMoodForHost(host: MenuMijiaWindowsApp, id: string): void {
  host.moods = saveMoodSnapshots(host.moods.filter((m) => m.id !== id));
  broadcastMoodSnapshotsSync();
  host.render();
}

function failOutcome(host: MenuMijiaWindowsApp, status: "executed" | "blocked" | "cancelled" | "failed", text: string, source: string, isError = true): HotkeyExecutionOutcome {
  host.replyBanner = { text, source, ...(isError ? { isError: true } : {}) };
  host.render();
  return { status, message: text };
}

export async function applyMoodForHost(host: MenuMijiaWindowsApp, id: string, options?: { readonly openPanelForModal?: boolean }): Promise<HotkeyExecutionOutcome> {
  const pref = host.settings.interfaceLanguage;
  const mood = host.moods.find((m) => m.id === id);
  if (!mood) return { status: "unavailable", label: id };
  const sep = pref === "en" ? ", " : "、";
  const moodLabel = tr3("氛围", "氛圍", "Mood", undefined, pref);
  const blockedLabel = tr3("已阻止", "已阻止", "Blocked", undefined, pref);
  const lockMsg = tr3("Windows 已锁定，已阻止设备控制。可在「设置 → 安全与提醒」中关闭此限制。", "Windows 已鎖定，已阻止裝置控制。可在「設定 → 安全與提醒」中關閉此限制。", "Windows is locked, so device control is blocked. Turn this off in Settings → Safety & Alerts.", undefined, pref);
  const miMsg = tr3("米家登录已过期，请先重新扫码登录", "米家登入已過期，請先重新掃碼登入", "Xiaomi Home session expired. Please sign in again.", undefined, pref);

  if (await isWorkstationLockBlockingControl(host)) return failOutcome(host, "blocked", lockMsg, blockedLabel);
  if (isMoodWriteBlockedByMiSession(host)) return failOutcome(host, "blocked", miMsg, blockedLabel);

  const startSource = host.sourceRevision;
  const startHome = host.homeRevision;
  const startSel = JSON.stringify(buildHostCapabilityContext(host).state.selection);

  const aliased = withAliases(host.layout, host.devices);
  const byId = new Map(aliased.map((d) => [d.id, d]));
  const steps: MoodStep[] = [];
  const offlineNames: string[] = [];
  const skippedNames: string[] = [];
  let capReject: string | null = null;

  for (const target of mood.targets) {
    const dev = byId.get(target.deviceId);
    if (!dev || moodDeviceScope(host, dev) !== target.sourceScope || moodEntityIdForDevice(dev) !== target.entityId) { skippedNames.push(target.name); continue; }
    if (!dev.isOnline || dev.telemetryStale) { offlineNames.push(dev.name); continue; }
    const gate = moodCapabilityAllowsDevice(host, dev);
    if (gate !== null) { capReject ??= gate; skippedNames.push(dev.name); continue; }
    const devSteps = moodTargetFields(target).map((f) => buildStepForField(host, aliased, dev, target, f)).filter((s): s is MoodStep => s !== null);
    if (devSteps.length === 0) skippedNames.push(dev.name); else steps.push(...devSteps);
  }

  if (steps.length === 0) {
    const names = [...offlineNames, ...skippedNames];
    const msg = capReject ?? (names.length > 0
      ? tr3("氛围「{name}」未执行，设备离线或不可用：{devices}", "氛圍「{name}」未執行，裝置離線或不可用：{devices}", 'Mood "{name}" could not run; offline or unavailable: {devices}', { name: mood.name, devices: names.join(sep) }, pref)
      : tr3("氛围「{name}」中没有可控制的设备", "氛圍「{name}」中沒有可控制的裝置", 'Mood "{name}" has no controllable devices', { name: mood.name }, pref));
    return failOutcome(host, "failed", msg, moodLabel);
  }

  const riskyNames = [...new Set(steps.filter((s) => s.requiresConfirmation).map((s) => s.deviceName))];
  if (riskyNames.length > 0) {
    if (options?.openPanelForModal && typeof host.manualControlConfirmationHandler !== "function") invokeTauriVoid("show_panel_for_url");
    const prompt = {
      title: tr3("确认应用氛围「{name}」", "確認套用氛圍「{name}」", 'Confirm mood "{name}"', { name: mood.name }, pref),
      message: tr3("应用「{name}」将控制高风险设备：{devices}。请确认环境安全后继续。", "套用「{name}」將控制高風險裝置：{devices}。請確認環境安全後繼續。", 'Applying "{name}" will control high-risk devices: {devices}. Please confirm it is safe.', { name: mood.name, devices: riskyNames.join(sep) }, pref),
      confirmTitle: tr3("确认执行", "確認執行", "Confirm & Apply", undefined, pref),
      cancelTitle: tr3("取消", "取消", "Cancel", undefined, pref),
    };
    const approved = typeof host.manualControlConfirmationHandler === "function"
      ? host.manualControlConfirmationHandler(prompt)
      : await new Promise<boolean>((resolve) => {
          host.pendingMoodConfirm?.resolve(false);
          host.pendingMoodConfirm = { moodId: mood.id, moodName: mood.name, riskyDeviceNames: riskyNames, resolve };
          syncPin(host);
          host.render();
        });
    if (!approved) return failOutcome(host, "cancelled", tr3("已取消应用氛围「{name}」", "已取消套用氛圍「{name}」", 'Cancelled mood "{name}"', { name: mood.name }, pref), moodLabel, false);
  }

  if (await isWorkstationLockBlockingControl(host)) return failOutcome(host, "blocked", lockMsg, blockedLabel);
  if (isMoodWriteBlockedByMiSession(host)) return failOutcome(host, "blocked", miMsg, blockedLabel);
  if (host.sourceRevision !== startSource || host.homeRevision !== startHome) {
    return failOutcome(host, "cancelled", tr3("数据源已切换，已取消应用氛围「{name}」", "資料來源已切換，已取消套用氛圍「{name}」", 'Source changed; cancelled mood "{name}"', { name: mood.name }, pref), blockedLabel);
  }
  if (JSON.stringify(buildHostCapabilityContext(host).state.selection) !== startSel) {
    return failOutcome(host, "blocked", tr3("设备控制权限已变更，已取消应用氛围「{name}」", "裝置控制權限已變更，已取消套用氛圍「{name}」", 'Device permissions changed; cancelled mood "{name}"', { name: mood.name }, pref), blockedLabel);
  }

  const undoBefore = host.lastUndoAction;
  const restoreMap = new Map<string, { commands: DeviceCommand[]; prior: SmartDevice }>();
  const restoreOrder: string[] = [];
  const latestClaims = new Map<string, DeviceWriteClaim>();
  const executedDevices = new Set<string>();
  const failedNames: string[] = [];
  let succeededCount = 0;

  for (const step of steps) {
    if (host.sourceRevision !== startSource || host.homeRevision !== startHome) break;
    if (await isWorkstationLockBlockingControl(host)) return failOutcome(host, "blocked", lockMsg, blockedLabel);
    const liveAliased = withAliases(host.layout, host.devices);
    const live = liveAliased.find((d) => d.id === step.target.deviceId);
    const claim = latestClaims.get(step.deviceId) ?? step.initialClaim;
    const validLive = live && live.isOnline && !live.telemetryStale && moodDeviceScope(host, live) === step.target.sourceScope &&
      moodEntityIdForDevice(live) === step.target.entityId && moodCapabilityAllowsDevice(host, live) === null && ownsDeviceWrite(host, claim);
    const rechecked = validLive ? moodTargetFields(step.target).map((f) => buildStepForField(host, liveAliased, live, step.target, f))
      .find((s): s is MoodStep => s !== null && JSON.stringify(s.command) === JSON.stringify(step.command) &&
        (step.requiresConfirmation ? s.requiresConfirmation && s.hazardProfileKey === step.hazardProfileKey : !s.requiresConfirmation)) : undefined;
    if (!rechecked) { if (!failedNames.includes(step.deviceName)) failedNames.push(step.deviceName); continue; }

    lockOptimistic(host, rechecked.deviceId);
    if (rechecked.command.kind === "setNumberValue") host.lastCoverPositions[rechecked.deviceId] = rechecked.command.value;
    const seqBefore = peekDeviceWriteSeq(host, rechecked.deviceId);
    const sendPromise = host.applyCommand(rechecked.command);
    if (peekDeviceWriteSeq(host, rechecked.deviceId) === seqBefore) claimDeviceWrite(host, rechecked.deviceId);
    const writeClaim = currentDeviceWriteClaim(host, rechecked.deviceId);
    if ((await sendPromise) && ownsDeviceWrite(host, writeClaim)) {
      latestClaims.set(rechecked.deviceId, writeClaim);
      succeededCount += 1;
      executedDevices.add(rechecked.deviceId);
      // Undo returns to the state the user saw when the mood was planned (and confirmed), not to
      // a value a refresh slipped in behind the confirmation prompt (#532 parity).
      if (step.restore.length > 0) {
        let entry = restoreMap.get(rechecked.deviceId);
        if (!entry) { entry = { commands: [], prior: step.priorDevice }; restoreMap.set(rechecked.deviceId, entry); restoreOrder.push(rechecked.deviceId); }
        entry.commands.unshift(...step.restore);
      }
    } else {
      // A failed sub-command still advanced the device's write seq. With no outside write since,
      // the mood keeps the device: its accepted earlier restores (brightness before a failed
      // color temperature) stay undoable and its later sub-commands may still run.
      if (ownsDeviceWrite(host, writeClaim)) latestClaims.set(rechecked.deviceId, writeClaim);
      if (!failedNames.includes(step.deviceName)) failedNames.push(step.deviceName);
    }
  }

  // A device the user (or anything else) wrote after the mood is theirs: its stale mood restore is
  // dropped now, and the batch keeps dropping it if it is taken over before Undo is pressed.
  const undoBatch = new MoodUndoBatch(new Map(restoreOrder.map((did) => [did, latestClaims.get(did)!])));
  const ownedOrder = restoreOrder.filter((did) => undoBatch.ownsDeviceWrite(host, did));
  const undoSteps: UndoStep[] = ownedOrder.map((deviceId) => ({ deviceId, commands: restoreMap.get(deviceId)!.commands }));
  const summary = tr3("已应用氛围「{name}」（{count} 台设备）", "已套用氛圍「{name}」（{count} 台裝置）", 'Applied mood "{name}" ({count} devices)', { name: mood.name, count: executedDevices.size }, pref);
  const newerUndoPublished = host.lastUndoAction !== null && host.lastUndoAction !== undoBefore;
  if (undoSteps.length > 0 && !newerUndoPublished) {
    const undoAction: UndoAction = { summary, steps: undoSteps, expiresAtMs: Date.now() + 8_000 };
    recordUndoKindSnapshots(undoAction, new Map(ownedOrder.map((did) => [did, restoreMap.get(did)!.prior.kind])));
    registerUndoActionBatch(undoAction, undoBatch);
    host.lastUndoAction = undoAction;
  }

  const incomplete = [...new Set([...offlineNames, ...skippedNames, ...failedNames])];
  if (succeededCount === 0) {
    const msg = incomplete.length > 0
      ? tr3("氛围「{name}」未能写入设备：{devices}", "氛圍「{name}」未能寫入裝置：{devices}", 'Mood "{name}" failed on: {devices}', { name: mood.name, devices: incomplete.join(sep) }, pref)
      : tr3("氛围「{name}」未执行任何设备", "氛圍「{name}」未執行任何裝置", 'Mood "{name}" did not execute on any device', { name: mood.name }, pref);
    return failOutcome(host, "failed", msg, moodLabel);
  }
  if (incomplete.length > 0) {
    return failOutcome(host, "executed", tr3("已应用氛围「{name}」，已跳过离线或不可用设备：{devices}", "已套用氛圍「{name}」，已跳過離線或不可用裝置：{devices}", 'Applied mood "{name}"; skipped offline/unavailable: {devices}', { name: mood.name, devices: incomplete.join(sep) }, pref), moodLabel);
  }
  return failOutcome(host, "executed", summary, moodLabel, false);
}

export function renderMoodActionsRow(host: MenuMijiaWindowsApp): string {
  if (!host.settings.showQuickActionsBar) return "";
  const pref = host.settings.interfaceLanguage;
  const captureBtn = `<button type="button" class="cc-quick-pill cc-mood-capture-pill" id="btn-mood-capture" data-quick-drawer-item><span class="cc-quick-icon" aria-hidden="true">+</span><span>${host.escapeHtml(tr3("保存当前为氛围", "儲存目前為氛圍", "Capture Current as Mood", undefined, pref))}</span></button>`;
  const moodPills = host.moods.map((m) =>
    `<span class="cc-mood-chip" data-mood-id="${host.escapeHtml(m.id)}"><button type="button" class="cc-quick-pill tint-purple cc-mood-apply" data-mood-apply="${host.escapeHtml(m.id)}"><span>${host.escapeHtml(m.name)}</span></button><button type="button" class="cc-mood-del" data-mood-delete="${host.escapeHtml(m.id)}" aria-label="${host.escapeHtml(tr3("删除氛围「{name}」", "刪除氛圍「{name}」", 'Delete mood "{name}"', { name: m.name }, pref))}">×</button></span>`
  ).join("");
  return `<section class="cc-mood-strip" data-quick-drawer-item aria-label="${host.escapeHtml(tr3("自定义氛围", "自訂氛圍", "Custom Moods", undefined, pref))}">${captureBtn}${moodPills}</section>`;
}

export function renderMoodPrompt(host: MenuMijiaWindowsApp): string {
  const pref = host.settings.interfaceLanguage;
  if (host.pendingMoodConfirm) {
    const { moodName, riskyDeviceNames } = host.pendingMoodConfirm;
    const devices = riskyDeviceNames.join(pref === "en" ? ", " : "、");
    return `<div class="cc-prompt-backdrop" data-mood-confirm-cancel></div><div class="cc-prompt" role="alertdialog" aria-modal="true" aria-label="${host.escapeHtml(tr3("确认应用氛围", "確認套用氛圍", "Confirm mood", undefined, pref))}"><strong>${host.escapeHtml(tr3("确认应用氛围「{name}」", "確認套用氛圍「{name}」", 'Confirm mood "{name}"', { name: moodName }, pref))}</strong><p style="margin: 6px 0; font-size: 13px; line-height: 1.45;">${host.escapeHtml(tr3("以下高风险设备将被控制：{devices}。请确认环境安全后继续。", "以下高風險裝置將被控制：{devices}。請確認環境安全後繼續。", "High-risk devices will be controlled: {devices}. Please confirm it is safe.", { devices }, pref))}</p><div class="cc-prompt-actions"><button type="button" class="cc-btn-secondary" id="btn-mood-confirm-cancel">${host.escapeHtml(tr3("取消", "取消", "Cancel", undefined, pref))}</button><button type="button" class="cc-btn-primary" id="btn-mood-confirm-apply">${host.escapeHtml(tr3("确认执行", "確認執行", "Confirm & Apply", undefined, pref))}</button></div></div>`;
  }
  if (!host.pendingMoodCapture) return "";
  const opts = [`<option value="${ALL_ROOMS_ID}"${host.pendingMoodCapture.roomId === ALL_ROOMS_ID ? " selected" : ""}>${host.escapeHtml(tr3("全部房间", "全部房間", "All Rooms", undefined, pref))}</option>`,
    ...host.moodAvailableRooms().map((r) => `<option value="${host.escapeHtml(r.id)}"${host.pendingMoodCapture?.roomId === r.id ? " selected" : ""}>${host.escapeHtml(r.name)}</option>`)].join("");
  const title = tr3("保存当前为氛围", "儲存目前為氛圍", "Capture Current as Mood", undefined, pref);
  return `<div class="cc-prompt-backdrop" data-mood-capture-cancel></div><form class="cc-prompt" id="mood-capture-form" role="dialog" aria-modal="true" aria-label="${host.escapeHtml(title)}"><strong>${host.escapeHtml(title)}</strong><label style="display:block;margin:8px 0 4px;font-size:12px;">${host.escapeHtml(tr3("范围房间", "範圍房間", "Room", undefined, pref))}</label><select id="mood-capture-room" style="width:100%;margin-bottom:8px;">${opts}</select><label style="display:block;margin-bottom:4px;font-size:12px;">${host.escapeHtml(tr3("氛围名称", "氛圍名稱", "Mood Name", undefined, pref))}</label><input type="text" id="mood-capture-name" maxlength="64" placeholder="${host.escapeHtml(tr3("例如：观影、阅读", "例如：觀影、閱讀", "e.g. Movie Night, Reading", undefined, pref))}" value="${host.escapeHtml(host.pendingMoodCapture.name)}" autocomplete="off" /><div class="cc-prompt-actions"><button type="button" class="cc-btn-secondary" id="btn-mood-capture-cancel">${host.escapeHtml(tr3("取消", "取消", "Cancel", undefined, pref))}</button><button type="submit" class="cc-btn-primary" id="btn-mood-capture-save">${host.escapeHtml(tr3("保存", "儲存", "Save", undefined, pref))}</button></div></form>`;
}

export function bindMoodPromptEventsAfterRender(host: MenuMijiaWindowsApp): void {
  if (host.pendingMoodConfirm) {
    const cancelBtn = host.root.querySelector<HTMLButtonElement>("#btn-mood-confirm-cancel");
    cancelBtn?.addEventListener("click", () => resolvePendingMoodConfirmation(host, false));
    host.root.querySelector("#btn-mood-confirm-apply")?.addEventListener("click", () => resolvePendingMoodConfirmation(host, true));
    host.root.querySelectorAll("[data-mood-confirm-cancel]").forEach((el) => el.addEventListener("click", () => resolvePendingMoodConfirmation(host, false)));
    if (cancelBtn && !host.root.querySelector(".cc-prompt")?.contains(document.activeElement)) cancelBtn.focus();
    return;
  }
  if (!host.pendingMoodCapture) return;
  const form = host.root.querySelector<HTMLFormElement>("#mood-capture-form");
  const roomSel = host.root.querySelector<HTMLSelectElement>("#mood-capture-room");
  const nameIn = host.root.querySelector<HTMLInputElement>("#mood-capture-name");
  roomSel?.addEventListener("change", () => { if (host.pendingMoodCapture) host.pendingMoodCapture = { ...host.pendingMoodCapture, roomId: roomSel.value }; });
  nameIn?.addEventListener("input", () => { if (host.pendingMoodCapture) host.pendingMoodCapture = { ...host.pendingMoodCapture, name: nameIn.value }; });
  host.root.querySelector("#btn-mood-capture-cancel")?.addEventListener("click", () => dismissPendingMoodPrompts(host));
  host.root.querySelectorAll("[data-mood-capture-cancel]").forEach((el) => el.addEventListener("click", () => dismissPendingMoodPrompts(host)));
  form?.addEventListener("submit", (e) => { e.preventDefault(); captureMoodForHost(host, nameIn?.value ?? host.pendingMoodCapture?.name ?? "", roomSel?.value ?? host.pendingMoodCapture?.roomId ?? ALL_ROOMS_ID); });
  if (nameIn && form && !form.contains(document.activeElement)) nameIn.focus();
}
