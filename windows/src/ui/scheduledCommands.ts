import type { MenuMijiaWindowsApp } from "./app.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import { t } from "../core/i18n.js";
import type { ScheduledCommand } from "../core/models.js";
import {
  isScheduledCommandsEnabled,
  missingScheduledCommandTargets,
} from "../core/scheduledCommands.js";
import type { PersistedSettings } from "./appTypes.js";
import {
  buildHostCapabilityContext,
  isDualSourceEnabled,
  isHostHaEnabled,
  resolveEnabledMiAccountsForHost,
  resolveHostMiSelectionState,
} from "./cloudRefresh.js";
import { AutomationRuleStore } from "../core/automationEngine.js";
import {
  evaluateDisabledUtteranceGate,
  evaluateIntentsWriteGate,
  parseTimerIdentityScope,
  revalidateAfterMiAccountReenable,
} from "../core/miAccountControl.js";
import { isWorkstationLockBlockingControl as isControlBlockedWhileLocked } from "./transport.js";

/**
 * Generation of the timer switch (P5d-TW). Every flip advances it, so a run that started before the
 * switch was turned off sees a stale generation and stops before its next device write — the same
 * rule the automation switch uses for its in-flight rules. Already accepted writes keep their
 * receipt and undo entry; only the remaining steps are dropped.
 */
const timerSwitchGenerations = new WeakMap<object, number>();

export function scheduledCommandsGeneration(host: object): number {
  return timerSwitchGenerations.get(host) ?? 0;
}

function advanceScheduledCommandsGeneration(host: object): void {
  timerSwitchGenerations.set(host, scheduledCommandsGeneration(host) + 1);
}

export function scheduledCommandIdentity(settings: PersistedSettings): string | null {
  switch (settings.connectionMode) {
    case "demo": return "demo";
    case "xiaomiCloud": return settings.miSession
      ? JSON.stringify(["xiaomiCloud", settings.miSession.userId, normalizeMiCloudRegion(settings.miSession.region)]) : null;
    case "homeAssistant": {
      if (!settings.haToken) return null;
      const identity = homeAssistantIdentity(settings.haBaseURL, settings.haToken);
      return identity ? JSON.stringify(["homeAssistant", identity]) : null;
    }
  }
}

export function scheduledCommandsReady(host: MenuMijiaWindowsApp): boolean {
  const identity = scheduledCommandIdentity(host.settings);
  if (identity === "demo") return true;
  if (host.settings.connectionMode === "homeAssistant" && !isHostHaEnabled(host)) {
    if (!isDualSourceEnabled(host) || resolveEnabledMiAccountsForHost(host).length === 0) {
      return false;
    }
  }
  return host.timerCredentialsReady && identity !== null &&
    host.timerSnapshot?.identity === identity && host.timerSnapshot.sourceRevision === host.sourceRevision;
}

export function markTimerSnapshotReady(host: MenuMijiaWindowsApp): void {
  const identity = scheduledCommandIdentity(host.settings);
  host.timerSnapshot = identity ? { identity, sourceRevision: host.sourceRevision } : null;
}

export function processScheduledCommands(host: MenuMijiaWindowsApp, nowMs = Date.now()): boolean {
  // Captured before the resume: a deferred resume can move overdue entries into the missed queue in
  // this very tick, and those rows need the same render/assistant-bar treatment as a due timer.
  const waitingBefore = host.scheduledCommands.length;
  const missedBefore = host.missedScheduledCommands.length;
  if (!isScheduledCommandsEnabled(host.settings)) {
    // Nothing fires and nothing is caught up while the switch is off. The park below is idempotent:
    // it also catches a waiting entry that appeared while the switch was already off (an older build
    // or a failed write), so a due timer can never slip through the gap.
    if (parkWaitingTimersForFeatureSwitch(host)) timerStorageFailure(host);
    return false;
  }
  // Re-enabling revalidates before anything may fire again; until the current source's snapshot is
  // back, entries stay parked and every tick retries (no silent catch-up, no stale-target write).
  if (host.scheduledCommandStore.hasFeaturePause() && !resumeScheduledCommandsAfterEnable(host, nowMs)) {
    return false;
  }
  const knownTargetIds = new Set<string>([
    ...host.devices.map((device) => device.id),
    ...host.scenes.map((scene) => scene.id),
  ]);
  const run = host.scheduledCommandStore.takeDue(
    scheduledCommandIdentity(host.settings),
    scheduledCommandsReady(host),
    nowMs,
    knownTargetIds,
  );
  if (run === null) {
    timerStorageFailure(host);
    return true;
  }
  if (host.missedScheduledCommands.length > missedBefore) {
    host.isShowingAssistantBar = true;
    host.queueBackgroundRender();
  }
  for (const item of run) void host.runScheduledCommand(item);
  return waitingBefore > 0 || host.missedScheduledCommands.length !== missedBefore;
}

/**
 * Scopes a parked timer that never recorded its own scopes is stamped with: the queue's own source,
 * or `demo` because the demo home is evaluated against `["demo", ...enabledConnectionScopes]`.
 * Without this a legacy demo timer would look foreign to the resume revalidation and stay parked.
 */
function queueScopesForTimer(identity: string): readonly string[] {
  const scope = parseTimerIdentityScope(identity);
  if (scope) return [scope];
  return identity === "demo" ? ["demo"] : [];
}

/**
 * Parks waiting timers for the switch. Returns whether the park needed a storage write and that
 * write failed, so the caller can report a storage problem instead of pretending it is off.
 */
function parkWaitingTimersForFeatureSwitch(host: MenuMijiaWindowsApp): boolean {
  if (!host.scheduledCommandStore.hasWaitingTimers()) return false;
  const snapshot = host.scheduledCommandStore.snapshotQueues();
  if (!host.scheduledCommandStore.pauseForFeatureSwitch(queueScopesForTimer)) return false;
  if (host.scheduledCommandStore.persist()) return false;
  host.scheduledCommandStore.restoreQueues(snapshot);
  return true;
}

/**
 * Turns the timer switch on or off (P5d-TW).
 *
 * Off parks the waiting timers under `TIMER_FEATURE_PAUSE_REASON` — plans, fire times, source
 * stamps, original partitions and any other pause reason survive — and advances the generation so a
 * run already in flight stops before its next write. On resumes with a revalidation first: every
 * target must still be enabled on an available source, entries that came due while the switch was
 * off go to the missed flow (never to an execution), and anything that cannot be verified yet stays
 * parked until the current source's snapshot is back.
 */
export function setScheduledCommandsRunning(
  host: MenuMijiaWindowsApp,
  enabled: boolean,
  nowMs = Date.now(),
): boolean {
  if (enabled === isScheduledCommandsEnabled(host.settings)) return true;
  advanceScheduledCommandsGeneration(host);
  if (!enabled) {
    const snapshot = host.scheduledCommandStore.snapshotQueues();
    const changed = host.scheduledCommandStore.pauseForFeatureSwitch(queueScopesForTimer);
    if (changed && !host.scheduledCommandStore.persist()) {
      // Fail closed: the timer stays armed rather than claiming an off state the disk never got.
      host.scheduledCommandStore.restoreQueues(snapshot);
      return false;
    }
    host.settings.scheduledCommandsEnabled = false;
    host.render();
    return true;
  }
  host.settings.scheduledCommandsEnabled = true;
  // A failure here is not a reason to refuse the switch: the entries keep the switch's pause reason
  // and every tick retries, so nothing fires before it has been revalidated.
  resumeScheduledCommandsAfterEnable(host, nowMs);
  host.render();
  return true;
}

/**
 * Revalidates the timers the switch is holding, then resumes them.
 *
 * Returns false when the current source is not verified yet (retried by the next tick) or when the
 * write failed (everything is restored, so nothing is silently released). Uses the shared
 * `revalidatePausedTimer` rules with `timersOnly`: the timer switch owns no rule pause, so turning
 * timers back on must not re-enable automation rules.
 */
export function resumeScheduledCommandsAfterEnable(host: MenuMijiaWindowsApp, nowMs = Date.now()): boolean {
  const activeIdentity = scheduledCommandIdentity(host.settings);
  const activeScope = activeIdentity === null ? null : parseTimerIdentityScope(activeIdentity);
  // Only queues of the current source can be verified now. A queue whose own source is inactive keeps
  // the switch's reason: releasing it here would leave those entries paused with no owner to retry
  // them, so they would never come back after switching back to that source.
  const releasable = new Set(
    host.scheduledCommandStore.featurePausedIdentities().filter(
      (identity) =>
        identity === activeIdentity ||
        (activeScope !== null && parseTimerIdentityScope(identity) === activeScope),
    ),
  );
  if (releasable.size === 0) return true;
  if (!scheduledCommandsReady(host)) return false;
  const snapshot = host.scheduledCommandStore.snapshotQueues();
  host.scheduledCommandStore.releaseFeaturePause(releasable);
  if (!host.scheduledCommandStore.persist()) {
    host.scheduledCommandStore.restoreQueues(snapshot);
    return false;
  }
  const resumed = revalidateAfterMiAccountReenable({
    context: buildHostCapabilityContext(host),
    scheduledCommandStore: host.scheduledCommandStore,
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore: new AutomationRuleStore(),
    nowMs,
    timersOnly: true,
  });
  if (!resumed) {
    host.scheduledCommandStore.restoreQueues(snapshot);
    return false;
  }
  return true;
}

/**
 * Runs a missed timer the user just confirmed ("Run Now"), following the store rule in
 * `CODING_STANDARDS.md` §7.
 *
 * The screen-lock guard runs **before** the entry leaves the list: a refused run stays in
 * `missedScheduledCommands` on screen and on disk, so the user can retry once the workstation is
 * unlocked. (Removing first and re-adding after the await lost the timer if the process exited in
 * between.) Once the guard passes, the entry is re-found by id in the same stretch without an
 * `await` that removes and persists it — a cancel, dismiss, or source switch during the lock probe
 * therefore makes this call a no-op instead of executing a stale copy.
 */
export async function confirmMissedScheduledCommand(
  host: MenuMijiaWindowsApp,
  id: string,
): Promise<void> {
  const preItem = host.missedScheduledCommands.find((entry) => entry.id === id);
  if (!preItem) return;
  // "Run Now" is a timer execution too: with the switch off nothing timer-driven is written, and the
  // entry stays exactly where it is so it can be run after timers are back on.
  if (!isScheduledCommandsEnabled(host.settings)) {
    host.replyBanner = { text: t("定时任务已关闭，开启后才能执行这条定时"), source: t("定时任务"), isError: true };
    host.render();
    return;
  }
  if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const capContext = buildHostCapabilityContext(host);
    const gateMsg =
      preItem.intents && preItem.intents.length > 0
        ? evaluateIntentsWriteGate({
            intents: preItem.intents,
            context: capContext,
            languagePreference: host.settings.interfaceLanguage,
          })
        : evaluateDisabledUtteranceGate({
            utterance: preItem.command,
            context: capContext,
            aliases: host.layout.aliases,
            languagePreference: host.settings.interfaceLanguage,
          });
    if (gateMsg !== null) {
      host.isShowingAssistantBar = true;
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      host.render();
      return;
    }
  }
  const identity = scheduledCommandIdentity(host.settings);
  const generation = scheduledCommandsGeneration(host);

  const needsNativeLockProbe =
    host.settings.blockControlWhileLocked &&
    typeof window.__TAURI_INTERNALS__?.invoke === "function";
  if (needsNativeLockProbe && (await isControlBlockedWhileLocked(host))) {
    host.replyBanner = { text: t("屏幕已锁定，已拦截设备控制指令"), source: t("锁屏保护"), isError: true };
    host.render();
    return;
  }

  // Everything below runs without an `await`, so nothing can change underneath the removal. The
  // switch and its generation are rechecked here too: turning timers off during the lock probe must
  // keep the entry for a later run instead of consuming it into a refused execution.
  if (!isScheduledCommandsEnabled(host.settings) || scheduledCommandsGeneration(host) !== generation) {
    host.replyBanner = { text: t("定时任务已关闭，开启后才能执行这条定时"), source: t("定时任务"), isError: true };
    host.render();
    return;
  }
  if (!scheduledCommandsReady(host) || scheduledCommandIdentity(host.settings) !== identity) {
    host.replyBanner = { text: t("请等待设备同步完成后再执行定时指令"), source: t("定时任务"), isError: true };
    host.render();
    return;
  }
  const index = host.missedScheduledCommands.findIndex((entry) => entry.id === id);
  if (index < 0) return;
  const item = host.missedScheduledCommands[index]!;
  if (missingScheduledCommandTargets(item, host.devices, host.scenes).length > 0) {
    host.isShowingAssistantBar = true;
    host.render();
    return;
  }
  const previous = host.missedScheduledCommands;
  host.missedScheduledCommands = previous.filter((entry) => entry.id !== id);
  if (!host.scheduledCommandStore.persist()) {
    host.missedScheduledCommands = previous;
    timerStorageFailure(host);
    return;
  }
  void host.runScheduledCommand(item);
  host.render();
}

export function cancelScheduledCommands(host: MenuMijiaWindowsApp, id?: string): number {
  const queue = host.scheduledCommandStore.queue(scheduledCommandIdentity(host.settings));
  const previous = {
    scheduledCommands: queue.scheduledCommands,
    missedScheduledCommands: queue.missedScheduledCommands,
    pausedScheduledCommands: queue.pausedScheduledCommands ?? [],
  };
  queue.scheduledCommands = queue.scheduledCommands.filter((item) => id !== undefined && item.id !== id);
  queue.missedScheduledCommands = queue.missedScheduledCommands.filter((item) => id !== undefined && item.id !== id);
  queue.pausedScheduledCommands = previous.pausedScheduledCommands.filter((entry) => id !== undefined && entry.command.id !== id);
  const count =
    previous.scheduledCommands.length +
    previous.missedScheduledCommands.length +
    previous.pausedScheduledCommands.length -
    queue.scheduledCommands.length -
    queue.missedScheduledCommands.length -
    queue.pausedScheduledCommands.length;
  if (!host.scheduledCommandStore.persist()) {
    Object.assign(queue, previous);
    timerStorageFailure(host);
    return -1;
  }
  return count;
}

export function enqueueScheduledCommand(host: MenuMijiaWindowsApp, item: ScheduledCommand): boolean {
  // A new timer would only be parked again: refuse it at the entry point instead of accepting a
  // timer that will not run.
  if (!isScheduledCommandsEnabled(host.settings)) {
    host.replyBanner = { text: t("定时任务已关闭，开启后才能新建定时"), source: t("定时任务"), isError: true };
    host.render();
    return false;
  }
  if (!scheduledCommandsReady(host)) {
    host.replyBanner = { text: t("请等待设备同步完成后再执行定时指令"), source: t("定时任务"), isError: true };
    host.render();
    return false;
  }
  if (!item.intents?.length) return false;
  const activeScopes = resolveHostMiSelectionState(host).selection.enabledConnectionScopes;
  const cloned = structuredClone(item);
  host.scheduledCommands.push(
    cloned.sourceScopes?.length || activeScopes.length === 0
      ? cloned
      : { ...cloned, sourceScopes: [...activeScopes] },
  );
  if (host.scheduledCommandStore.persist()) return true;
  host.scheduledCommands = host.scheduledCommands.filter((entry) => entry.id !== item.id);
  timerStorageFailure(host);
  return false;
}

function timerStorageFailure(host: MenuMijiaWindowsApp): void {
  host.replyBanner = { text: t("定时指令无法保存，请重试"), source: t("定时任务"), isError: true };
  host.render();
}
