/**
 * P5d-TW: Windows 定时任务 switch, pause retention and revalidated resume.
 *
 * Acceptance mapping:
 * 1. The switch rides the same carrier as P5a-W / P5b-W / P5d-AW: one settings boolean, an explicit
 *    `false` is the only "off", a missing key keeps the always-on behavior every upgrade and a
 *    manifest-less fresh install already had, and an unreadable/absent identity never writes a value.
 * 2. Off stops the corresponding plans: nothing fires at its time, nothing is caught up afterwards,
 *    and the waiting / missed partitions plus every paused entry stay on disk.
 * 3. Back on revalidates before anything may fire: still-valid future timers re-arm, timers that came
 *    due in between go to the missed flow (never a silent run), unusable targets stay paused, and a
 *    source that is not verified yet keeps everything parked until its snapshot returns.
 * 4. Pausing composes with P4b-W's device-type pause: an entry can carry both reasons, and releasing
 *    one reason never releases the other.
 * 5. A run that is in flight when the switch closes stops before its next write and keeps the
 *    receipt/undo of the steps that already succeeded.
 * 6. The settings page exposes the switch and everything ships in zh-Hans / zh-Hant / en.
 */

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { loadSettings } from "../src/ui/settings.js";
import { setLanguage, t } from "../src/core/i18n.js";
import { DEVICE_CATEGORY_IDS } from "../src/core/capabilityManifest.js";
import { revalidateAfterMiAccountReenable } from "../src/core/miAccountControl.js";
import { AutomationRuleStore } from "../src/core/automationEngine.js";
import {
  TIMER_FEATURE_PAUSE_REASON,
  isScheduledCommandsEnabled,
} from "../src/core/scheduledCommands.js";
import type { ScheduledCommand } from "../src/core/models.js";
import {
  applyMiotTypePruneSnapshot,
  buildHostCapabilityContext,
  resolveHostMiSelectionState,
} from "../src/ui/cloudRefresh.js";
import {
  confirmMissedScheduledCommand,
  enqueueScheduledCommand,
  processScheduledCommands,
  scheduledCommandIdentity,
  setScheduledCommandsRunning,
} from "../src/ui/scheduledCommands.js";
import { resolveSettingsAnchorTab, searchSettings, UNRESTRICTED_SETTINGS_AVAILABILITY } from "../src/ui/settingsSearch.js";

const now = 1_800_000_000_000;

function timer(id: string, fireTimestampMs: number, targetId = "light.study_desk"): ScheduledCommand {
  return {
    id,
    command: `${id} 关闭台灯`,
    reply: `${id} 关闭台灯`,
    delaySeconds: 10,
    fireTimestampMs,
    intents: [{ targetId, operation: { kind: "power", isOn: false } }],
  };
}

let dom: Window;
const windows: Window[] = [];

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  windows.push(dom);
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  for (const instance of windows.splice(0)) {
    await closeTestWindow(instance);
  }
});

function app(): MenuMijiaWindowsApp {
  const root = document.querySelector<HTMLElement>("#app");
  assert.ok(root);
  return new MenuMijiaWindowsApp(root);
}

async function restart(): Promise<MenuMijiaWindowsApp> {
  const saved = Array.from({ length: localStorage.length }, (_, index) => localStorage.key(index)).flatMap(
    (key) => (key ? [[key, localStorage.getItem(key) ?? ""]] : []),
  );
  await closeTestWindow(dom);
  dom = mountTestWindow({ stubInterval: true });
  windows.push(dom);
  for (const [key, value] of saved) if (key !== undefined && value !== undefined) localStorage.setItem(key, value);
  const instance = app();
  await setImmediate();
  return instance;
}

function queue(instance: MenuMijiaWindowsApp) {
  return instance.scheduledCommandStore.queue(scheduledCommandIdentity(instance.settings));
}

function paused(instance: MenuMijiaWindowsApp) {
  return queue(instance).pausedScheduledCommands ?? [];
}

function fakeExecutor(instance: MenuMijiaWindowsApp): ScheduledCommand[] {
  const calls: ScheduledCommand[] = [];
  instance.executeIntents = async (intents) => {
    calls.push({ id: String(calls.length), command: "", reply: "", delaySeconds: 1, fireTimestampMs: 0, intents: [...intents] });
    return true;
  };
  return calls;
}

describe("Timer switch carrier (P5d-TW)", () => {
  it("only an explicit false turns timers off and a missing key keeps them on", () => {
    assert.equal(isScheduledCommandsEnabled({}), true);
    assert.equal(isScheduledCommandsEnabled({ scheduledCommandsEnabled: undefined }), true);
    assert.equal(isScheduledCommandsEnabled({ scheduledCommandsEnabled: true }), true);
    assert.equal(isScheduledCommandsEnabled({ scheduledCommandsEnabled: false }), false);

    const read = (value: unknown): boolean | undefined => {
      const stored: Record<string, unknown> = { connectionMode: "demo", hasCompletedOnboarding: true };
      if (value !== undefined) stored.scheduledCommandsEnabled = value;
      localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
      return loadSettings().settings.scheduledCommandsEnabled;
    };
    assert.equal(read(false), false);
    assert.equal(read(true), true);
    // A legacy record and a brand-new one carry no key: both keep the always-on behavior.
    assert.equal(read(undefined), undefined);
    // A malformed value is not treated as a user choice in either direction.
    assert.equal(read("false"), undefined);
    assert.equal(read(0), undefined);
    assert.equal(isScheduledCommandsEnabled({ scheduledCommandsEnabled: read(undefined) }), true);
  });
});

describe("Timer switch: off", () => {
  it("parks waiting timers, keeps every partition, and never fires or catches up", async () => {
    let instance = app();
    const due = timer("t-due", now + 10_000);
    instance.scheduledCommands.push(due);
    instance.missedScheduledCommands.push(timer("m-already", now - 60_000));
    instance.scheduledCommandStore.persist();
    const calls = fakeExecutor(instance);

    assert.equal(setScheduledCommandsRunning(instance, false), true);
    instance.saveSettings();
    assert.equal(instance.settings.scheduledCommandsEnabled, false);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["m-already"]);
    const parked = paused(instance);
    assert.deepEqual(parked.map((entry) => entry.command.id), ["t-due"]);
    assert.equal(parked[0]?.originalPartition, "waiting");
    assert.deepEqual(parked[0]?.pausedCapabilities, [TIMER_FEATURE_PAUSE_REASON]);
    assert.equal(parked[0]?.command.fireTimestampMs, due.fireTimestampMs, "fire time survives");

    // The clock passes the fire time while the switch is off: no run, no catch-up, no new missed row.
    assert.equal(processScheduledCommands(instance, due.fireTimestampMs + 60_001), false);
    assert.equal(calls.length, 0);
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["m-already"]);
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["t-due"]);

    // Turned off means turned off across a restart too.
    instance = await restart();
    const restartedCalls = fakeExecutor(instance);
    assert.equal(instance.settings.scheduledCommandsEnabled, false);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["t-due"]);
    processScheduledCommands(instance, due.fireTimestampMs + 120_000);
    assert.equal(restartedCalls.length, 0);
  });

  it("parks a waiting timer that was written while the switch was already off", async () => {
    const instance = app();
    instance.settings.scheduledCommandsEnabled = false;
    queue(instance).scheduledCommands.push(timer("legacy-waiting", now + 1000));
    instance.scheduledCommandStore.persist();
    const calls = fakeExecutor(instance);
    assert.equal(processScheduledCommands(instance, now + 2000), false);
    assert.equal(calls.length, 0);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["legacy-waiting"]);
  });

  it("refuses new timers and manual runs while the entry itself is kept", async () => {
    const instance = app();
    instance.settings.scheduledCommandsEnabled = false;
    instance.missedScheduledCommands.push(timer("m-off", now - 5000));
    instance.scheduledCommandStore.persist();
    const calls = fakeExecutor(instance);

    assert.equal(enqueueScheduledCommand(instance, timer("new-while-off", now + 5000)), false);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.match(instance.replyBanner?.text ?? "", /定时任务已关闭/);

    await confirmMissedScheduledCommand(instance, "m-off");
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["m-off"]);
    assert.equal(calls.length, 0);
    assert.match(instance.replyBanner?.text ?? "", /定时任务已关闭/);
  });

  it("keeps the switch on and the timer armed when the park cannot be saved", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("t-keep", now + 10_000));
    assert.equal(instance.scheduledCommandStore.persist(), true);
    const realPersist = instance.scheduledCommandStore.persist.bind(instance.scheduledCommandStore);
    instance.scheduledCommandStore.persist = () => false;
    try {
      assert.equal(setScheduledCommandsRunning(instance, false), false);
    } finally {
      instance.scheduledCommandStore.persist = realPersist;
    }
    assert.notEqual(instance.settings.scheduledCommandsEnabled, false);
    assert.deepEqual(instance.scheduledCommands.map((entry) => entry.id), ["t-keep"]);
    assert.deepEqual(paused(instance), []);
  });
});

describe("Timer switch: back on", () => {
  it("revalidates: valid timers re-arm, overdue ones enter the missed flow, nothing fires silently", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("future", now + 600_000), timer("became-due", now + 60_000));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);
    const calls = fakeExecutor(instance);

    // The re-enable happens at a point where "became-due" is already in the past.
    const enableAt = now + 120_000;
    assert.equal(setScheduledCommandsRunning(instance, true, enableAt), true);
    assert.deepEqual(instance.scheduledCommands.map((entry) => entry.id), ["future"]);
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["became-due"]);
    assert.deepEqual(paused(instance), []);
    assert.equal(calls.length, 0, "an overdue timer is never executed by the switch itself");

    processScheduledCommands(instance, instance.missedScheduledCommands[0]!.fireTimestampMs + 1000);
    assert.equal(calls.length, 0, "still waiting for the explicit Run Now");
  });

  it("keeps timers whose target is gone paused and moves them to the missed flow", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("orphan", now + 600_000, "light.no_longer_here"));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);
    setScheduledCommandsRunning(instance, true);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["orphan"]);
  });

  it("does not re-arm before the current source's snapshot is verified", () => {
    const instance = app();
    // A real connection identity has no snapshot until the first successful refresh.
    instance.settings.connectionMode = "xiaomiCloud";
    instance.settings.miSession = {
      userId: "10001", cUserId: "", serviceToken: "tok", ssecurity: "sec", passToken: "", region: "cn",
    };
    instance.scheduledCommands.push(timer("waiting-for-source", now + 600_000));
    instance.scheduledCommandStore.persist();
    assert.equal(setScheduledCommandsRunning(instance, false), true);

    instance.timerSnapshot = null;
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    assert.equal(instance.scheduledCommands.length, 0, "no re-arm without a verified source");
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["waiting-for-source"]);
    assert.deepEqual(paused(instance)[0]?.pausedCapabilities, [TIMER_FEATURE_PAUSE_REASON]);
    assert.equal(processScheduledCommands(instance, now + 1000), false);
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["waiting-for-source"]);
  });

  it("retries the resume on the next tick when the write failed", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("retry", now + 600_000));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);

    const realPersist = instance.scheduledCommandStore.persist.bind(instance.scheduledCommandStore);
    instance.scheduledCommandStore.persist = () => false;
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    instance.scheduledCommandStore.persist = realPersist;
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["retry"]);
    assert.equal(instance.scheduledCommands.length, 0);

    processScheduledCommands(instance, now + 1000);
    assert.deepEqual(paused(instance), []);
    assert.deepEqual(instance.scheduledCommands.map((entry) => entry.id), ["retry"]);
  });

  it("keeps the switch's reason on a queue whose source is inactive until that source returns", () => {
    const instance = app();
    // A timer queue of a source that is not the active one (e.g. the user switched to HA).
    const miIdentity = JSON.stringify(["xiaomiCloud", "10001", "cn"]);
    const foreign = instance.scheduledCommandStore.queue(miIdentity);
    foreign.scheduledCommands.push(timer("mi-timer", now + 600_000));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);
    assert.deepEqual(
      foreign.pausedScheduledCommands?.map((entry) => [entry.command.id, entry.pausedCapabilities]),
      [["mi-timer", [TIMER_FEATURE_PAUSE_REASON]]],
    );

    // Turning timers on for the demo home cannot verify the Mi queue, so its reason stays. Dropping it
    // here would strand the entry with no owner left to retry it after switching back.
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    assert.deepEqual(foreign.pausedScheduledCommands?.map((entry) => entry.pausedCapabilities), [
      [TIMER_FEATURE_PAUSE_REASON],
    ]);
    assert.equal(foreign.scheduledCommands.length, 0);

    // Back on the Mi source the queue is verified and classified again.
    instance.settings.connectionMode = "xiaomiCloud";
    instance.settings.miSession = {
      userId: "10001", cUserId: "", serviceToken: "tok", ssecurity: "sec", passToken: "", region: "cn",
    };
    instance.timerCredentialsReady = true;
    instance.timerSnapshot = { identity: miIdentity, sourceRevision: instance.sourceRevision };
    processScheduledCommands(instance, now + 1000);
    assert.deepEqual(foreign.pausedScheduledCommands?.map((entry) => entry.pausedCapabilities), []);
    assert.equal(foreign.scheduledCommands.length + foreign.missedScheduledCommands.length, 1);
  });

  it("reports the missed rows a deferred resume creates on the same tick", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("late", now - 1000));
    setScheduledCommandsRunning(instance, false);

    const realPersist = instance.scheduledCommandStore.persist.bind(instance.scheduledCommandStore);
    instance.scheduledCommandStore.persist = () => false;
    assert.equal(setScheduledCommandsRunning(instance, true), true, "the switch flips even when the resume write fails");
    instance.scheduledCommandStore.persist = realPersist;
    assert.equal(instance.missedScheduledCommands.length, 0);
    assert.equal(processScheduledCommands(instance, now), true, "the tick must report the newly missed timer");
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["late"]);
    assert.equal(instance.isShowingAssistantBar, true);
  });

  it("keeps the missed entry when the switch closes during the lock probe", async () => {
    const instance = app();
    instance.missedScheduledCommands.push(timer("probe", now - 5000));
    instance.scheduledCommandStore.persist();
    const calls = fakeExecutor(instance);
    instance.settings.blockControlWhileLocked = true;
    let releaseLock: (value: boolean) => void = () => {};
    const lockProbe = new Promise<boolean>((resolve) => {
      releaseLock = resolve;
    });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: { invoke: async (command: string) => (command === "is_workstation_locked" ? lockProbe : undefined) },
      configurable: true,
    });

    const run = confirmMissedScheduledCommand(instance, "probe");
    await setImmediate();
    assert.equal(setScheduledCommandsRunning(instance, false), true);
    releaseLock(false);
    await run;
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["probe"]);
    assert.equal(calls.length, 0);
    assert.match(instance.replyBanner?.text ?? "", /定时任务已关闭/);
  });

  it("does not release a pause another owner still holds, and its own release does not either", () => {
    const instance = app();
    const entry = {
      command: timer("dual", now + 600_000),
      originalPartition: "waiting" as const,
      sourceScopes: ["demo"],
      pausedCapabilities: ["light"],
    };
    queue(instance).pausedScheduledCommands = [entry];
    instance.scheduledCommandStore.persist();

    // Off adds this switch's reason without touching P4b-W's.
    assert.equal(setScheduledCommandsRunning(instance, false), true);
    assert.deepEqual(paused(instance)[0]?.pausedCapabilities, ["light", TIMER_FEATURE_PAUSE_REASON]);

    // The light type comes back while timers are still off: the type's own resume path (P4b-W calls
    // the shared revalidation) cannot release a timer the timer switch is holding.
    instance.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS);
    assert.equal(
      revalidateAfterMiAccountReenable({
        context: buildHostCapabilityContext(instance),
        scheduledCommandStore: instance.scheduledCommandStore,
        activeTimerIdentity: scheduledCommandIdentity(instance.settings),
        ruleStore: new AutomationRuleStore(),
        nowMs: now,
      }),
      true,
    );
    assert.deepEqual(paused(instance).map((item) => item.command.id), ["dual"]);
    assert.ok(paused(instance)[0]?.pausedCapabilities.includes(TIMER_FEATURE_PAUSE_REASON));

    // Timers come back on, but the device type is off again: only this switch's reason goes.
    instance.setEnabledDeviceCategories(["climate"]);
    assert.equal(setScheduledCommandsRunning(instance, true, now), true);
    assert.deepEqual(paused(instance).map((item) => item.command.id), ["dual"]);
    assert.deepEqual(paused(instance)[0]?.pausedCapabilities, ["light"]);
    assert.equal(instance.scheduledCommands.length, 0);

    // The device type's own release path is what finally arms it.
    instance.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS);
    assert.equal(
      revalidateAfterMiAccountReenable({
        context: buildHostCapabilityContext(instance),
        scheduledCommandStore: instance.scheduledCommandStore,
        activeTimerIdentity: scheduledCommandIdentity(instance.settings),
        ruleStore: new AutomationRuleStore(),
        nowMs: now,
        timersOnly: true,
      }),
      true,
    );
    assert.deepEqual(paused(instance), []);
    assert.deepEqual(instance.scheduledCommands.map((item) => item.id), ["dual"]);
  });

  it("keeps a timer paused when only its hidden card is left in the identity index", () => {
    const instance = app();
    instance.scheduledCommands.push(timer("hidden-light-timer", now + 600_000, "light.study_desk"));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);
    instance.setEnabledDeviceCategories(["climate"]);
    // A real home keeps a closed type's card in the identity index (architecture.md §D), so the
    // revalidation can tell "type is off" apart from "device is gone" and keep the timer paused.
    applyMiotTypePruneSnapshot(instance, {
      safetyDevices: [],
      safetyDeviceFacets: {},
      hiddenDevices: [{
        id: "light.study_desk", name: "书房台灯", category: "light", connection: null, sourceScope: "demo",
        isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
        safetySignals: [], readKeys: ["light.study_desk"], safetyReadKeys: [],
      }],
    });
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(paused(instance).map((item) => item.command.id), ["hidden-light-timer"]);
    assert.deepEqual(paused(instance)[0]?.pausedCapabilities, [], "no reason is left; the type gate holds it");
    assert.deepEqual(instance.missedScheduledCommands, []);
    assert.equal(resolveHostMiSelectionState(instance).selection.enabledCategories.includes("light"), false);

    // The type's own release path (P4b-W adds the categories and completes the revalidation) arms it.
    applyMiotTypePruneSnapshot(instance, null);
    instance.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS);
    revalidateAfterMiAccountReenable({
      context: buildHostCapabilityContext(instance),
      scheduledCommandStore: instance.scheduledCommandStore,
      activeTimerIdentity: scheduledCommandIdentity(instance.settings),
      ruleStore: new AutomationRuleStore(),
      nowMs: now,
      timersOnly: true,
    });
    assert.deepEqual(paused(instance), []);
    assert.deepEqual(instance.scheduledCommands.map((item) => item.id), ["hidden-light-timer"]);
  });

  it("never arms or runs a timer whose device type is off in the demo home", async () => {
    const instance = app();
    instance.scheduledCommands.push(timer("light-timer", now + 600_000));
    instance.scheduledCommandStore.persist();
    setScheduledCommandsRunning(instance, false);
    // P4b-W rebuilds the demo sample home when a type closes, so the target leaves this home instead
    // of staying behind as a hidden card. The revalidation must then send the timer to the missed flow
    // — user-visible, never fired — rather than re-arming it against a card that is not there.
    instance.setEnabledDeviceCategories(["climate"]);
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    assert.equal(instance.scheduledCommands.length, 0);
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["light-timer"]);
    assert.deepEqual(paused(instance), []);
    const calls = fakeExecutor(instance);
    await confirmMissedScheduledCommand(instance, "light-timer");
    assert.equal(calls.length, 0, "the closed type cannot be run around through the missed card");
    assert.deepEqual(instance.missedScheduledCommands.map((entry) => entry.id), ["light-timer"]);

    // Nothing is stranded: after the type returns the same entry runs normally.
    instance.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS);
    await confirmMissedScheduledCommand(instance, "light-timer");
    assert.equal(calls.length, 1);
    assert.deepEqual(instance.missedScheduledCommands, []);
  });
});

describe("Timer switch: in-flight run", () => {
  it("stops before the next command and keeps the applied steps' receipt and undo", async () => {
    const instance = app();
    const applied: string[] = [];
    const realApply = instance.applyCommand.bind(instance);
    instance.applyCommand = async (command) => {
      applied.push(command.entityId ?? "");
      return realApply(command);
    };
    let allowed = true;
    await instance.executeIntents(
      [
        { targetId: "light.living_ceiling", operation: { kind: "power", isOn: false } },
        { targetId: "light.study_desk", operation: { kind: "power", isOn: false } },
      ],
      "关闭两盏灯",
      t("定时任务"),
      {
        recordHabits: false,
        concurrency: 1,
        canContinue: () => {
          const keepGoing = allowed;
          allowed = false;
          return keepGoing;
        },
      },
    );
    assert.deepEqual(instance.lastUndoAction?.steps.map((step) => step.deviceId), ["light.living_ceiling"]);
    assert.equal(instance.lastUndoAction?.steps.length, 1);
  });

  it("wires the switch and its generation into the timer run", async () => {
    const instance = app();
    let captured: (() => boolean) | undefined;
    instance.executeIntents = async (_intents, _reply, _source, options) => {
      captured = options?.canContinue;
      return true;
    };
    await instance.runScheduledCommand(timer("wired", now + 1000));
    assert.ok(captured, "a timer run must pass a continue check");
    assert.equal(captured!(), true);
    assert.equal(setScheduledCommandsRunning(instance, false), true);
    assert.equal(captured!(), false, "the same closure refuses once the switch closes");

    // A run that was stopped this way says so instead of failing silently.
    instance.executeIntents = async () => false;
    const stopped = instance.runScheduledCommand(timer("stopped", now + 2000));
    assert.equal(setScheduledCommandsRunning(instance, true), true);
    await stopped;
    assert.match(instance.replyBanner?.text ?? "", /定时任务开关已改变/);
  });
});

describe("Timer switch: settings entry", () => {
  it("renders the switch, persists the choice and exposes a search anchor", async () => {
    const instance = app();
    instance.activeSheet = "settings";
    instance.render();
    const toggle = document.querySelector<HTMLInputElement>("#settings-scheduled-commands-enabled");
    assert.ok(toggle, "the switch must be reachable from Settings");
    assert.equal(toggle!.checked, true);
    assert.ok(document.querySelector('[data-settings-anchor="scheduledCommands"]'));
    assert.equal(resolveSettingsAnchorTab("scheduledCommands", false), "safety");
    const hit = searchSettings("定时任务", UNRESTRICTED_SETTINGS_AVAILABILITY).hits.find(
      (entry) => entry.anchor === "scheduledCommands",
    );
    assert.ok(hit, "定时任务 must be searchable");

    instance.scheduledCommands.push(timer("ui-off", now + 60_000));
    instance.scheduledCommandStore.persist();
    toggle!.checked = false;
    toggle!.dispatchEvent(new window.Event("change"));
    assert.equal(loadSettings().settings.scheduledCommandsEnabled, false);
    assert.deepEqual(paused(instance).map((entry) => entry.command.id), ["ui-off"]);
    assert.equal(instance.scheduledCommands.length, 0);
  });

  it("ships the new wording in all three languages", () => {
    setLanguage("zh-Hans");
    assert.equal(t("运行定时任务"), "运行定时任务");
    setLanguage("zh-Hant");
    assert.equal(t("运行定时任务"), "執行定時任務");
    setLanguage("en");
    assert.equal(t("运行定时任务"), "Run Scheduled Commands");
    setLanguage("zh-Hans");
    assert.match(t("定时任务已关闭，开启后才能新建定时"), /定时任务已关闭/);
  });
});
