import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { afterEach, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow, setWindowFocused } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  RESUME_BURST_DEBOUNCE_MS,
  RESUME_MAX_DELAY_MS,
  RESUME_RECOVERY_COOLDOWN_MS,
  ResumeRecoveryController,
  bindGlobalKeys,
  bindLifecycleRecovery,
  disposeAppLifecycle,
  startTimerLoop,
  type LifecycleEventTarget,
  type LifecycleScheduler,
  type ResumeRecoveryHost,
} from "../src/ui/appLifecycle.js";
import { CLOUD_REFRESH_VISIBLE_MS } from "../src/core/models.js";
import { setLanguage } from "../src/core/i18n.js";

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const WINDOWS_DIR = resolve(TEST_DIR, "..");

interface ScheduledTask {
  readonly id: number;
  readonly kind: "timeout" | "interval";
  readonly handler: () => void;
  readonly delayMs: number;
  nextRunAtMs: number;
  cancelled: boolean;
}

class FakeLifecycleScheduler implements LifecycleScheduler {
  public currentMs: number;
  public activeTimeoutCount = 0;
  public activeIntervalCount = 0;
  public totalIntervalsCreated = 0;
  public totalIntervalsCleared = 0;
  private nextId = 1;
  private readonly tasks = new Map<number, ScheduledTask>();

  constructor(initialMs = 10_000) {
    this.currentMs = initialMs;
  }

  public readonly now = (): number => this.currentMs;

  public readonly setTimeout = (handler: () => void, delayMs: number): number => {
    const id = this.nextId++;
    this.activeTimeoutCount += 1;
    this.tasks.set(id, {
      id,
      kind: "timeout",
      handler,
      delayMs,
      nextRunAtMs: this.currentMs + Math.max(0, delayMs),
      cancelled: false,
    });
    return id;
  };

  public readonly clearTimeout = (handle: unknown): void => {
    const task = this.tasks.get(handle as number);
    if (!task || task.kind !== "timeout" || task.cancelled) return;
    task.cancelled = true;
    this.tasks.delete(task.id);
    this.activeTimeoutCount -= 1;
  };

  public readonly setInterval = (handler: () => void, intervalMs: number): number => {
    const id = this.nextId++;
    this.activeIntervalCount += 1;
    this.totalIntervalsCreated += 1;
    this.tasks.set(id, {
      id,
      kind: "interval",
      handler,
      delayMs: Math.max(1, intervalMs),
      nextRunAtMs: this.currentMs + Math.max(1, intervalMs),
      cancelled: false,
    });
    return id;
  };

  public readonly clearInterval = (handle: unknown): void => {
    const task = this.tasks.get(handle as number);
    if (!task || task.kind !== "interval" || task.cancelled) return;
    task.cancelled = true;
    this.tasks.delete(task.id);
    this.activeIntervalCount -= 1;
    this.totalIntervalsCleared += 1;
  };

  public advanceBy(ms: number): void {
    const targetMs = this.currentMs + ms;
    while (true) {
      let nextTask: ScheduledTask | null = null;
      for (const task of this.tasks.values()) {
        if (task.cancelled || task.nextRunAtMs > targetMs) continue;
        if (!nextTask || task.nextRunAtMs < nextTask.nextRunAtMs || (task.nextRunAtMs === nextTask.nextRunAtMs && task.id < nextTask.id)) {
          nextTask = task;
        }
      }
      if (!nextTask) break;
      this.currentMs = nextTask.nextRunAtMs;
      if (nextTask.kind === "timeout") {
        nextTask.cancelled = true;
        this.tasks.delete(nextTask.id);
        this.activeTimeoutCount -= 1;
        nextTask.handler();
      } else {
        nextTask.nextRunAtMs += nextTask.delayMs;
        nextTask.handler();
      }
    }
    this.currentMs = targetMs;
  }
}

class FakeEventTarget implements LifecycleEventTarget {
  private readonly listeners = new Map<string, Set<(event: Event) => void>>();

  public addEventListener(type: string, listener: (event: Event) => void): void {
    let set = this.listeners.get(type);
    if (!set) {
      set = new Set();
      this.listeners.set(type, set);
    }
    set.add(listener);
  }

  public removeEventListener(type: string, listener: (event: Event) => void): void {
    this.listeners.get(type)?.delete(listener);
  }

  public dispatch(type: string, event: Event = { type } as Event): void {
    const set = this.listeners.get(type);
    if (!set) return;
    for (const listener of [...set]) {
      listener(event);
    }
  }

  public listenerCount(type?: string): number {
    if (type !== undefined) return this.listeners.get(type)?.size ?? 0;
    let total = 0;
    for (const set of this.listeners.values()) total += set.size;
    return total;
  }
}

interface MockLifecycleHost extends ResumeRecoveryHost {
  settings: {
    connectionMode: string;
    miSession: unknown;
  };
  activeSheet: string;
  isSyncingCloud: boolean;
  isPollingQR: boolean;
  lastCloudRefreshAt: number | null;
  cloudValuesStale: boolean;
  haConnectionError: string | null;
  root: {
    isConnected: boolean;
  };
  pendingCloudRender: boolean;
  lastUndoAction: { expiresAtMs: number } | null;
  isRecordingHotkey: boolean;
  isGrokBallStageExpanded: boolean;
  cameraLive: { activeLiveCameraId: string | null; liveCameraHidden: boolean };
  refreshCalls: boolean[];
  renderCalls: number;
  backgroundRenderCalls: number;
  panelVisible: boolean;
  isPanelVisible(): boolean;
  refreshDevices(silent?: boolean): Promise<void>;
  render(): void;
  queueBackgroundRender(): void;
  hasBlockingPanelInteraction(): boolean;
  maybeRefreshProactiveInBackground(): void;
  syncGrokBallEmotion(): void;
}

function createMockHost(overrides: Partial<MockLifecycleHost> = {}): MockLifecycleHost {
  const host: MockLifecycleHost = {
    settings: {
      connectionMode: "xiaomiCloud",
      miSession: { userId: "123456", serviceToken: "tok", ssecurity: "sec", region: "cn" },
    },
    activeSheet: "none",
    isSyncingCloud: false,
    isPollingQR: false,
    lastCloudRefreshAt: null,
    cloudValuesStale: false,
    haConnectionError: null,
    root: { isConnected: true },
    pendingCloudRender: false,
    lastUndoAction: null,
    isRecordingHotkey: false,
    isGrokBallStageExpanded: false,
    cameraLive: { activeLiveCameraId: null, liveCameraHidden: false },
    refreshCalls: [],
    renderCalls: 0,
    backgroundRenderCalls: 0,
    panelVisible: true,
    isPanelVisible() {
      return host.panelVisible;
    },
    async refreshDevices(silent = false) {
      host.refreshCalls.push(silent);
      host.lastCloudRefreshAt = overrides.lastCloudRefreshAt ?? host.lastCloudRefreshAt;
    },
    render() {
      host.renderCalls += 1;
    },
    queueBackgroundRender() {
      host.backgroundRenderCalls += 1;
    },
    hasBlockingPanelInteraction() {
      return false;
    },
    maybeRefreshProactiveInBackground() {},
    syncGrokBallEmotion() {},
    ...overrides,
  };
  return host;
}

describe("Tauri backgroundThrottling configuration", () => {
  it("configures backgroundThrottling = disabled on the main window and matches Tauri config schema", () => {
    const conf = JSON.parse(
      readFileSync(resolve(WINDOWS_DIR, "src-tauri/tauri.conf.json"), "utf8"),
    ) as {
      app?: {
        windows?: Array<Record<string, unknown>>;
      };
    };
    const cliEntry = fileURLToPath(import.meta.resolve("@tauri-apps/cli"));
    const schema = JSON.parse(
      readFileSync(resolve(dirname(cliEntry), "config.schema.json"), "utf8"),
    ) as {
      definitions: {
        WindowConfig: {
          properties: Record<string, { anyOf?: Array<{ $ref?: string; type?: string }> }>;
        };
        BackgroundThrottlingPolicy: {
          oneOf: Array<{ enum: string[] }>;
        };
      };
    };

    const windowProps = schema.definitions.WindowConfig.properties;
    assert.ok(windowProps.backgroundThrottling, "WindowConfig schema must define backgroundThrottling");
    assert.ok(
      windowProps.backgroundThrottling.anyOf?.some(
        (entry) => entry.$ref === "#/definitions/BackgroundThrottlingPolicy",
      ),
      "WindowConfig.backgroundThrottling must reference BackgroundThrottlingPolicy",
    );

    const allowedPolicies = schema.definitions.BackgroundThrottlingPolicy.oneOf.flatMap(
      (variant) => variant.enum,
    );
    assert.deepEqual(allowedPolicies.sort(), ["disabled", "suspend", "throttle"]);

    const mainWindow = conf.app?.windows?.find((win) => win.label === "main");
    assert.ok(mainWindow, "tauri.conf.json must define the main window");
    assert.equal(mainWindow.backgroundThrottling, "disabled");
    assert.ok(
      allowedPolicies.includes(mainWindow.backgroundThrottling as string),
      "configured backgroundThrottling value must be valid per schema",
    );
  });
});

describe("ResumeRecoveryController deterministic lifecycle hardening", () => {
  it("coalesces a visibilitychange + focus + online + resume burst into one debounced refresh", () => {
    const scheduler = new FakeLifecycleScheduler(20_000);
    const host = createMockHost({ lastCloudRefreshAt: 0 });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    controller.trigger("visibility");
    scheduler.advanceBy(40);
    controller.trigger("focus");
    scheduler.advanceBy(40);
    controller.trigger("online");
    scheduler.advanceBy(40);
    controller.trigger("resume");

    assert.equal(host.refreshCalls.length, 0, "burst must wait for debounce before firing");
    assert.equal(controller.hasPendingFlush, true);

    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS - 1);
    assert.equal(host.refreshCalls.length, 0);

    scheduler.advanceBy(1);
    assert.deepEqual(host.refreshCalls, [true]);
    assert.equal(controller.hasPendingFlush, false);
  });

  it("caps continuous bursts with maxDelayMs so recovery cannot starve indefinitely", () => {
    const scheduler = new FakeLifecycleScheduler(30_000);
    const host = createMockHost({ lastCloudRefreshAt: 0 });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      debounceMs: 200,
      maxDelayMs: 600,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    // Fire triggers every 150ms for 900ms — naive debouncing would starve past 600ms.
    controller.trigger("focus");
    scheduler.advanceBy(150);
    controller.trigger("visibility");
    scheduler.advanceBy(150);
    controller.trigger("focus");
    scheduler.advanceBy(150);
    controller.trigger("visibility");
    scheduler.advanceBy(150); // total elapsed = 600ms === maxDelayMs

    assert.deepEqual(host.refreshCalls, [true]);
    assert.equal(scheduler.activeTimeoutCount, 0);
    assert.ok(RESUME_MAX_DELAY_MS >= RESUME_BURST_DEBOUNCE_MS);
  });

  it("cancels show-only refresh when the panel hides again before debounce settles", () => {
    const scheduler = new FakeLifecycleScheduler(20_000);
    let visible = true;
    const host = createMockHost({ lastCloudRefreshAt: 0 });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      isDocumentVisible: () => visible,
      isWindowFocused: () => visible,
    });

    controller.trigger("visibility");
    controller.trigger("focus");
    scheduler.advanceBy(50);

    visible = false;
    controller.trigger("visibility");
    assert.equal(controller.hasPendingFlush, false, "hiding clears show-only debounce timer");

    scheduler.advanceBy(500);
    assert.equal(host.refreshCalls.length, 0);
  });

  it("avoids storming when healthy and recently refreshed, but refreshes once visible interval is due", () => {
    const scheduler = new FakeLifecycleScheduler(10_000);
    const host = createMockHost({ lastCloudRefreshAt: 8_500 });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    // Only 1.5s elapsed (< CLOUD_REFRESH_VISIBLE_MS = 6000ms) and healthy -> skip.
    controller.trigger("visibility");
    controller.trigger("focus");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(host.refreshCalls.length, 0);

    // Advance past visible threshold (8500 + 6000 = 14500) -> prompts refresh on show.
    scheduler.advanceBy(CLOUD_REFRESH_VISIBLE_MS);
    controller.trigger("visibility");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(host.refreshCalls, [true]);
  });

  it("triggers prompt recovery on online/resume when stale or after offline, with cooldown anti-storm", () => {
    const scheduler = new FakeLifecycleScheduler(10_000);
    let navOnline = false;
    const host = createMockHost({
      lastCloudRefreshAt: 9_800,
      cloudValuesStale: true,
    });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      isDocumentVisible: () => false,
      isWindowFocused: () => false,
      isNavigatorOnline: () => navOnline,
    });

    // While offline in xiaomiCloud mode, focus/visibility must not storm.
    controller.noteOffline();
    controller.trigger("focus");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(host.refreshCalls.length, 0);

    // Coming online recovers promptly even while tray window is hidden.
    navOnline = true;
    controller.trigger("online");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(host.refreshCalls, [true]);

    // A second online flap within cooldown does not storm the backend.
    scheduler.advanceBy(500);
    controller.trigger("online");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(host.refreshCalls.length, 1);

    // After cooldown expires, another resume recovers again.
    scheduler.advanceBy(RESUME_RECOVERY_COOLDOWN_MS);
    controller.trigger("resume");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(host.refreshCalls, [true, true]);
  });

  it("drops queued online/resume recovery when connectivity goes offline before debounce, preserving cooldown for real reconnect", () => {
    const scheduler = new FakeLifecycleScheduler(10_000);
    let navOnline = true;
    const cloudHost = createMockHost({
      lastCloudRefreshAt: 9_800,
      cloudValuesStale: true,
    });
    const cloudController = new ResumeRecoveryController(cloudHost, {
      scheduler,
      isDocumentVisible: () => false,
      isWindowFocused: () => false,
      isNavigatorOnline: () => navOnline,
    });

    cloudController.trigger("online");
    cloudController.trigger("resume");
    scheduler.advanceBy(50);
    navOnline = false;
    cloudController.noteOffline();
    assert.equal(cloudController.hasPendingFlush, false);

    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(cloudHost.refreshCalls.length, 0);

    // Real reconnect within cooldown still fires immediately after debounce because cooldown was not poisoned.
    scheduler.advanceBy(500);
    navOnline = true;
    cloudController.trigger("online");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(cloudHost.refreshCalls, [true]);

    const haHost = createMockHost({
      settings: { connectionMode: "homeAssistant", miSession: null },
      lastCloudRefreshAt: 9_800,
      cloudValuesStale: true,
    });
    const haController = new ResumeRecoveryController(haHost, {
      scheduler,
      isDocumentVisible: () => false,
      isWindowFocused: () => false,
      isNavigatorOnline: () => navOnline,
    });

    haController.trigger("online");
    scheduler.advanceBy(50);
    // Simulate connectivity dropping without noteOffline() before flush executes.
    navOnline = false;
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(haHost.refreshCalls.length, 0);

    scheduler.advanceBy(500);
    navOnline = true;
    haController.trigger("online");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(haHost.refreshCalls, [true]);
  });

  it("respects onboarding/settings/QR/syncing guards and cancels pending debounce on dispose", () => {
    const scheduler = new FakeLifecycleScheduler(50_000);
    const host = createMockHost({ lastCloudRefreshAt: 0, activeSheet: "settings" });
    const controller = new ResumeRecoveryController(host, {
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    controller.trigger("focus");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(host.refreshCalls.length, 0, "settings sheet blocks background refresh");

    host.activeSheet = "none";
    host.isSyncingCloud = true;
    controller.trigger("focus");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.equal(host.refreshCalls.length, 0, "in-flight sync blocks duplicate refresh");

    host.isSyncingCloud = false;
    controller.trigger("online");
    assert.equal(scheduler.activeTimeoutCount, 1);
    controller.dispose();
    assert.equal(controller.isDisposed, true);
    assert.equal(scheduler.activeTimeoutCount, 0);

    scheduler.advanceBy(5_000);
    controller.trigger("online");
    scheduler.advanceBy(5_000);
    assert.equal(host.refreshCalls.length, 0, "disposed controller never fires");
  });
});

describe("bindLifecycleRecovery, startTimerLoop & idempotent teardown", () => {
  it("prevents duplicate intervals/listeners on re-bind and cleans up idempotently on dispose", () => {
    const scheduler = new FakeLifecycleScheduler(20_000);
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const host = createMockHost({ lastCloudRefreshAt: 0 });

    startTimerLoop(host as unknown as MenuMijiaWindowsApp, { scheduler, intervalMs: 1000 });
    startTimerLoop(host as unknown as MenuMijiaWindowsApp, { scheduler, intervalMs: 1000 });
    assert.equal(scheduler.activeIntervalCount, 1, "re-starting timer loop replaces previous interval");
    assert.equal(scheduler.totalIntervalsCleared, 1);

    bindLifecycleRecovery(host, {
      window: win,
      document: doc,
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });
    bindLifecycleRecovery(host, {
      window: win,
      document: doc,
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    assert.equal(doc.listenerCount("visibilitychange"), 1);
    assert.equal(doc.listenerCount("resume"), 1);
    assert.equal(win.listenerCount("focus"), 1);
    assert.equal(win.listenerCount("online"), 1);
    assert.equal(win.listenerCount("offline"), 1);
    assert.equal(win.listenerCount("pagehide"), 1);

    doc.dispatch("visibilitychange");
    win.dispatch("focus");
    scheduler.advanceBy(RESUME_BURST_DEBOUNCE_MS);
    assert.deepEqual(host.refreshCalls, [true]);

    // Dispose once and twice (idempotent).
    disposeAppLifecycle(host);
    disposeAppLifecycle(host);

    assert.equal(scheduler.activeIntervalCount, 0);
    assert.equal(scheduler.activeTimeoutCount, 0);
    assert.equal(doc.listenerCount(), 0);
    assert.equal(win.listenerCount(), 0);

    scheduler.advanceBy(120_000);
    doc.dispatch("visibilitychange");
    win.dispatch("online");
    scheduler.advanceBy(1_000);
    assert.deepEqual(host.refreshCalls, [true], "disposed host fires no further refreshes");
  });

  it("auto-disposes interval and listeners when host root detaches or pagehide fires", () => {
    const scheduler = new FakeLifecycleScheduler(20_000);
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const host = createMockHost({ lastCloudRefreshAt: 0 });

    startTimerLoop(host as unknown as MenuMijiaWindowsApp, { scheduler, intervalMs: 1000 });
    bindLifecycleRecovery(host, {
      window: win,
      document: doc,
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });

    host.root.isConnected = false;
    scheduler.advanceBy(1000);

    assert.equal(scheduler.activeIntervalCount, 0, "detached host self-cancels interval");
    assert.equal(doc.listenerCount(), 0, "detached host removes document listeners");
    assert.equal(win.listenerCount(), 0, "detached host removes window listeners");
    assert.equal(host.refreshCalls.length, 0);

    // Re-attach and verify pagehide also disposes cleanly.
    host.root.isConnected = true;
    startTimerLoop(host as unknown as MenuMijiaWindowsApp, { scheduler, intervalMs: 1000 });
    bindLifecycleRecovery(host, {
      window: win,
      document: doc,
      scheduler,
      isDocumentVisible: () => true,
      isWindowFocused: () => true,
    });
    assert.equal(scheduler.activeIntervalCount, 1);

    win.dispatch("pagehide");
    assert.equal(scheduler.activeIntervalCount, 0);
    assert.equal(doc.listenerCount(), 0);
    assert.equal(win.listenerCount(), 0);
  });

  it("tracks and removes global key listeners on re-bind and disposeAppLifecycle", () => {
    const win = new FakeEventTarget();
    const host = createMockHost();

    bindGlobalKeys(host as unknown as MenuMijiaWindowsApp, { window: win });
    bindGlobalKeys(host as unknown as MenuMijiaWindowsApp, { window: win });
    assert.equal(win.listenerCount("blur"), 1);
    assert.equal(win.listenerCount("keydown"), 1);

    disposeAppLifecycle(host);
    assert.equal(win.listenerCount("blur"), 0);
    assert.equal(win.listenerCount("keydown"), 0);
  });
});

describe("MenuMijiaWindowsApp integrated tray/resume lifecycle", () => {
  let dom: Window | null = null;
  let restoreFocus: (() => void) | null = null;

  afterEach(async () => {
    restoreFocus?.();
    restoreFocus = null;
    if (dom) {
      await closeTestWindow(dom);
      dom = null;
    }
  });

  it("wires MenuMijiaWindowsApp resume recovery and idempotent dispose() without leaking timers", async () => {
    dom = mountTestWindow();
    installCssEscape();
    setLanguage("zh-Hans");

    const timeouts: Array<{ delay: number; handler: () => void; cleared: boolean }> = [];
    const intervals: Array<{ handler: () => void; cleared: boolean }> = [];
    let nowMs = 50_000;
    const realDateNow = Date.now;
    Date.now = () => nowMs;

    Object.defineProperty(window, "setTimeout", {
      configurable: true,
      value: (handler: () => void, delay = 0) => {
        const entry = { delay, handler, cleared: false };
        timeouts.push(entry);
        return timeouts.length;
      },
    });
    Object.defineProperty(window, "clearTimeout", {
      configurable: true,
      value: (id: number) => {
        const entry = timeouts[id - 1];
        if (entry) entry.cleared = true;
      },
    });
    Object.defineProperty(window, "setInterval", {
      configurable: true,
      value: (handler: () => void) => {
        const entry = { handler, cleared: false };
        intervals.push(entry);
        return intervals.length;
      },
    });
    Object.defineProperty(window, "clearInterval", {
      configurable: true,
      value: (id: number) => {
        const entry = intervals[id - 1];
        if (entry) entry.cleared = true;
      },
    });

    let haSnapshots = 0;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "secure_store_get") return null;
          if (cmd === "ha_snapshot") {
            haSnapshots += 1;
            return { areas: [], devices: [], entities: [], states: [] };
          }
          return undefined;
        },
      },
    });

    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          connectionMode: "homeAssistant",
          haBaseURL: "http://127.0.0.1:8123",
          haToken: "test-token",
          hasCompletedOnboarding: true,
        }),
      );
      localStorage.setItem(
        "menumijia.windows.update.v1",
        JSON.stringify({ lastCheckedAtMs: nowMs, release: null }),
      );

      const app = new MenuMijiaWindowsApp(document.querySelector("#app")!);
      assert.equal(intervals.length, 1);
      assert.equal(intervals[0]!.cleared, false);

      // Simulate stale cache after backgrounding, then tray show + focus burst.
      app.lastCloudRefreshAt = 0;
      restoreFocus = setWindowFocused(true);
      Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
      document.dispatchEvent(new window.Event("visibilitychange"));
      window.dispatchEvent(new window.Event("focus"));

      const debounceTimers = timeouts.filter((t) => t.delay === RESUME_BURST_DEBOUNCE_MS);
      assert.equal(debounceTimers.length, 2, "second burst event resets the debounce timer");
      assert.equal(debounceTimers[0]!.cleared, true, "prior debounce timer was cancelled");
      assert.equal(debounceTimers[1]!.cleared, false);
      assert.equal(haSnapshots, 0);

      nowMs += RESUME_BURST_DEBOUNCE_MS;
      debounceTimers[1]!.handler();
      await Promise.resolve();
      await Promise.resolve();
      assert.equal(haSnapshots, 1, "debounced visibility+focus burst triggers one HA recovery");

      // Idempotent dispose clears the timer loop and suppresses subsequent events.
      app.dispose();
      app.dispose();
      assert.equal(intervals[0]!.cleared, true);

      nowMs += 60_000;
      window.dispatchEvent(new window.Event("online"));
      intervals[0]!.handler();
      assert.equal(haSnapshots, 1, "disposed app ignores subsequent online events and ticks");
    } finally {
      Date.now = realDateNow;
    }
  });
});
