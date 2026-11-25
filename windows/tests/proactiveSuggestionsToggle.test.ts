/**
 * P5b-W: Windows 主动建议 alone on/off, plus the fresh-install AI default.
 *
 * Acceptance mapping:
 * 1. 主动建议 has its own switch; closed means the shared tick never enters the suggestion
 *    branch, no ambient signature/ranking is computed, no prompt or count appears, and no
 *    suggestion-specific request is sent. Safety alerts, undo expiry and scheduled commands
 *    keep their cadence on the same tick.
 * 2. A suggestion run that is in flight when the switch closes is dropped (proactive epoch).
 * 3. A brand-new install resolves its switches from `Shared/capability-manifest.json`
 *    (`ai-assistant: false`, `proactive-suggestions: true`), while upgrades keep what they had
 *    and an uncertain identity read changes nothing (fail-closed).
 * 4. zh-Hans / zh-Hant / en wording ships for every new string.
 */

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, element, installCssEscape, mountTestWindow, setWindowFocused } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { startTimerLoop, type LifecycleScheduler } from "../src/ui/appLifecycle.js";
import { markTimerSnapshotReady } from "../src/ui/scheduledCommands.js";
import { setLanguage } from "../src/core/i18n.js";
import { loadSharedCapabilityManifest } from "../src/core/capabilityManifest.js";
import { resolveCapabilityInstallSelection } from "../src/core/capabilityReferenceVerdict.js";
import { applyFreshInstallFeatureSwitches } from "../src/core/freshInstallDefaults.js";
import {
  isAiAssistantEnabled,
  isProactiveSuggestionsEnabled,
} from "../src/core/assistant.js";
import {
  currentProactiveSuggestions,
  maybeRefreshProactiveInBackground,
  proactiveHasConsumer,
} from "../src/ui/proactive.js";
import { getHostActivityCenter } from "../src/ui/activityStackView.js";
import type { HttpRequest } from "../src/core/miCloudClient.js";
import type { HttpResponse } from "../src/core/miCloud/session.js";

let dom: Window;

function mountApp(persisted: Record<string, unknown> | null): MenuMijiaWindowsApp {
  if (persisted) localStorage.setItem(STORAGE_KEY, JSON.stringify(persisted));
  const root = document.querySelector<HTMLElement>("#app");
  assert.ok(root);
  return new MenuMijiaWindowsApp(root);
}

function mountDemoApp(): MenuMijiaWindowsApp {
  return mountApp({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false });
}

/** A local AI endpoint, so the suggestion branch has a consumer without keys or consent. */
function enableLocalSuggestions(app: MenuMijiaWindowsApp): void {
  app.settings.connectionMode = "xiaomiCloud";
  app.settings.miSession = {
    userId: "10001",
    cUserId: "",
    serviceToken: "tok",
    ssecurity: "sec",
    passToken: "",
    region: "cn",
  };
  app.settings.assistantBaseURL = "http://127.0.0.1:11434/v1";
}

interface ScheduledTask {
  readonly id: number;
  readonly kind: "timeout" | "interval";
  readonly handler: () => void;
  cancelled: boolean;
}

/** Minimal scheduler: only the shared 1s interval matters here. */
class FakeScheduler implements LifecycleScheduler {
  public currentMs: number;
  private nextId = 1;
  private readonly tasks = new Map<number, ScheduledTask>();
  private intervalHandler: (() => void) | null = null;

  constructor(initialMs = 100_000) {
    this.currentMs = initialMs;
  }

  public readonly now = (): number => this.currentMs;

  public readonly setTimeout = (handler: () => void, delayMs: number): number => {
    const id = this.nextId++;
    this.tasks.set(id, { id, kind: "timeout", handler, cancelled: false });
    void delayMs;
    return id;
  };

  public readonly clearTimeout = (handle: unknown): void => {
    const task = this.tasks.get(handle as number);
    if (task) task.cancelled = true;
    this.tasks.delete(handle as number);
  };

  public readonly setInterval = (handler: () => void, intervalMs: number): number => {
    void intervalMs;
    this.intervalHandler = handler;
    return this.nextId++;
  };

  public readonly clearInterval = (): void => {
    this.intervalHandler = null;
  };

  public advanceBy(ms: number): void {
    this.currentMs += ms;
    this.intervalHandler?.();
  }
}

interface DeferredTransport {
  calls: string[];
  release: (index: number, response: HttpResponse) => void;
  stub: (req: HttpRequest) => Promise<HttpResponse>;
}

function deferredTransport(): DeferredTransport {
  const calls: string[] = [];
  const resolvers: Array<(response: HttpResponse) => void> = [];
  return {
    calls,
    release: (index, response) => resolvers[index]?.(response),
    stub: (req: HttpRequest): Promise<HttpResponse> => {
      calls.push(req.url);
      return new Promise<HttpResponse>((resolve) => resolvers.push(resolve));
    },
  };
}

function chatCompletion(content: unknown): HttpResponse {
  return {
    status: 200,
    headers: {},
    body: JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] }),
  };
}

async function settle(times = 4): Promise<void> {
  for (let i = 0; i < times; i += 1) await setImmediate();
}

/** Counts reads of the ambient readings that only the suggestion signature needs. */
function countAmbientReads(app: MenuMijiaWindowsApp): () => number {
  const descriptor = Object.getOwnPropertyDescriptor(MenuMijiaWindowsApp.prototype, "computedEnvironmentReadings");
  let reads = 0;
  Object.defineProperty(app, "computedEnvironmentReadings", {
    configurable: true,
    get() {
      reads += 1;
      return descriptor?.get?.call(app) ?? [];
    },
  });
  return () => reads;
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("P5b-W acceptance 1: 主动建议 is a switch of its own", () => {
  it("is on unless the user turned it off, independently of the AI switch", () => {
    const aiOff: { aiAssistantEnabled?: boolean; proactiveSuggestionsEnabled?: boolean } = { aiAssistantEnabled: false };
    const suggestionsOff: { aiAssistantEnabled?: boolean; proactiveSuggestionsEnabled?: boolean } = {
      proactiveSuggestionsEnabled: false,
    };
    assert.equal(isProactiveSuggestionsEnabled({}), true, "missing field keeps legacy behavior");
    assert.equal(isProactiveSuggestionsEnabled({ proactiveSuggestionsEnabled: true }), true);
    assert.equal(isProactiveSuggestionsEnabled({ proactiveSuggestionsEnabled: false }), false);
    // Two independent switches: neither one implies the other.
    assert.equal(isProactiveSuggestionsEnabled(aiOff), true);
    assert.equal(isAiAssistantEnabled(suggestionsOff), true);
  });

  it("returns no suggestions and reads no ambient data while the switch is off", () => {
    const app = mountDemoApp();
    enableLocalSuggestions(app);
    const ambientReads = countAmbientReads(app);

    app.settings.proactiveSuggestionsEnabled = false;
    app.aiProactiveSuggestions = [
      { id: "habit:cached", title: "打开书房台灯", confidencePercent: 80, intents: [] },
    ];
    app.aiProactiveSignature = "any";

    assert.deepEqual(currentProactiveSuggestions(app), [], "a stale AI cache must not surface either");
    assert.equal(ambientReads(), 0, "the ambient signature must not be computed");

    app.settings.proactiveSuggestionsEnabled = true;
    app.aiProactiveSignature = "wrong signature";
    currentProactiveSuggestions(app);
    assert.ok(ambientReads() > 0, "sanity: the enabled path does read the ambient signature");
  });

  it("never enters the suggestion branch on the shared tick, while safety, undo and timers keep running", async () => {
    const app = mountDemoApp();
    enableLocalSuggestions(app);
    app.settings.proactiveSuggestionsEnabled = false;
    app.settings.eventAutomationEnabled = false;
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });
    app.refreshDevices = async () => {};

    const scheduler = new FakeScheduler();
    const realDateNow = Date.now;
    Date.now = () => scheduler.now();
    let suggestionRuns = 0;
    app.maybeRefreshProactiveInBackground = () => {
      suggestionRuns += 1;
    };

    const center = getHostActivityCenter(app);
    app.devices = [
      ...app.devices,
      {
        id: "sensor.study_battery",
        name: "书房门磁",
        roomId: "room_study",
        roomName: "书房",
        model: "lumi.sensor_magnet.aq2",
        isOnline: true,
        kind: { kind: "sensor", battery: 10, temperature: null, humidity: null },
      },
    ];
    let ranScheduled = 0;
    app.runScheduledCommand = async () => {
      ranScheduled += 1;
    };

    const stopLoop = startTimerLoop(app, { scheduler, intervalMs: 1000 });
    try {
      assert.equal(proactiveHasConsumer(app), false, "the switch alone is enough to close the consumer");

      // The scheduled-command branch needs its identity snapshot ready, as a real refresh would.
      await settle();
      markTimerSnapshotReady(app);

      app.lastUndoAction = { summary: "关闭书房台灯", steps: [], expiresAtMs: scheduler.now() + 1_000 };
      app.scheduledCommands = [
        {
          id: "sched-p5bw",
          command: "关闭书房台灯",
          intents: [],
          delaySeconds: 2,
          fireTimestampMs: scheduler.now() + 2_000,
          reply: "已定时关闭书房台灯",
        },
      ];

      for (let i = 0; i < 4; i += 1) {
        scheduler.advanceBy(1_000);
        await settle();
      }

      assert.equal(suggestionRuns, 0, "the tick must not reach the suggestion branch at all");
      assert.equal(transport.calls.length, 0, "and must not send a suggestion request");
      assert.equal(app.isRefreshingProactive, false);
      assert.equal(app.aiProactiveSignature, null, "no ambient signature is claimed");
      assert.equal(app.aiProactiveSuggestions, null);
      assert.deepEqual(currentProactiveSuggestions(app), [], "nothing is prompted or counted");

      assert.equal(app.lastUndoAction, null, "undo expiry still runs");
      assert.equal(ranScheduled, 1, "scheduled commands still fire");
      assert.ok(
        center.recentSafetyAlerts.some((entry) => entry.alert.category === "lowBattery"),
        "safety alert evaluation still runs",
      );

      // Positive control: with the switch on, the very same tick does reach the branch.
      app.settings.proactiveSuggestionsEnabled = true;
      scheduler.advanceBy(1_000);
      await settle();
      assert.equal(suggestionRuns, 1, "the branch is live once the switch is back on");
    } finally {
      stopLoop();
      Date.now = realDateNow;
    }
  });

  it("discards an in-flight suggestion result when the switch is turned off", async () => {
    const app = mountDemoApp();
    enableLocalSuggestions(app);
    const transport = deferredTransport();
    Object.defineProperty(app, "transport", { value: transport.stub, configurable: true });

    maybeRefreshProactiveInBackground(app);
    await setImmediate();
    assert.equal(transport.calls.length, 1, "the run started while the switch was on");
    assert.equal(app.isRefreshingProactive, true);

    // Drive the real settings toggle so the handler's epoch advance is covered.
    app.activeSheet = "settings";
    app.render();
    const toggle = element("#settings-proactive-enabled") as HTMLInputElement;
    assert.equal(toggle.checked, true, "an unset switch renders as on");
    toggle.checked = false;
    toggle.dispatchEvent(new window.Event("change"));

    assert.equal(app.settings.proactiveSuggestionsEnabled, false);
    assert.equal(app.isRefreshingProactive, false, "closing the switch clears the in-flight marker");
    assert.equal(app.proactiveRetryAfterMs, null);

    transport.release(0, chatCompletion({ suggestions: [{ id: "smart:stale", title: "打开客厅灯", intents: [] }] }));
    await settle();

    assert.equal(app.aiProactiveSignature, null, "a discarded run must not claim the signature");
    assert.equal(app.aiProactiveSuggestions, null, "and must not publish its suggestions");
    assert.equal(transport.calls.length, 1, "a closed switch sends no retry either");
    assert.deepEqual(currentProactiveSuggestions(app), []);
  });
});

describe("P5b-W acceptance 2: fresh installs follow the manifest, upgrades keep their values", () => {
  const manifest = loadSharedCapabilityManifest();
  /** P4a-W's own resolver, used the way startup uses it: identity first, defaults second. */
  const resolve = (evidence: Parameters<typeof resolveCapabilityInstallSelection>[0]) =>
    resolveCapabilityInstallSelection(evidence, manifest);

  it("resolves the manifest defaults for a brand-new install", () => {
    const settings: { aiAssistantEnabled?: boolean; proactiveSuggestionsEnabled?: boolean; eventAutomationEnabled?: boolean } = {};
    const outcome = applyFreshInstallFeatureSwitches(settings, resolve({}));
    assert.equal(outcome.applied, true);
    assert.equal(settings.aiAssistantEnabled, false, "ai-assistant is defaultOnFreshInstall: false");
    assert.equal(settings.proactiveSuggestionsEnabled, true, "proactive-suggestions defaults on");
    assert.equal(settings.eventAutomationEnabled, true);
    assert.deepEqual([...outcome.changedSwitches].sort(), ["aiAssistantEnabled", "eventAutomationEnabled", "proactiveSuggestionsEnabled"]);
  });

  it("leaves every other install mode and every explicit choice alone", () => {
    const otherModes = [
      resolve({ hasLegacySettingsOrOnboarding: true }),
      resolve({
        explicitSelection: {
          enabledConnections: [],
          enabledConnectionScopes: [],
          enabledFeatures: ["ai-assistant", "proactive-suggestions"],
          enabledCategories: [],
        },
      }),
      resolve({ identityReadFailure: "credential_vault_read_failed" }),
    ];
    assert.deepEqual(
      otherModes.map((install) => install.mode),
      ["legacyPreserved", "explicit", "uncertainFallback"],
    );
    for (const install of otherModes) {
      const settings: { aiAssistantEnabled?: boolean; proactiveSuggestionsEnabled?: boolean } = {};
      assert.equal(applyFreshInstallFeatureSwitches(settings, install).applied, false, install.mode);
      assert.equal(settings.aiAssistantEnabled, undefined, `${install.mode}: nothing written`);
      assert.equal(settings.proactiveSuggestionsEnabled, undefined, `${install.mode}: nothing written`);
    }
    const chosen = { aiAssistantEnabled: true, proactiveSuggestionsEnabled: false };
    applyFreshInstallFeatureSwitches(chosen, resolve({}));
    assert.equal(chosen.aiAssistantEnabled, true, "an explicit choice survives the fresh-install default");
    assert.equal(chosen.proactiveSuggestionsEnabled, false);
  });

  it("follows the manifest's dependency rule when a default depends on another capability", () => {
    // `proactive-suggestions` and `ai-assistant` both have no hard dependency today; the resolved
    // fresh-install selection is what decides, so a cascade the manifest adds later is honoured
    // without touching this module.
    const fresh = resolve({});
    assert.equal(fresh.mode, "freshInstall");
    assert.deepEqual(
      [...fresh.selection.enabledFeatures].sort(),
      ["camera-live", "event-automation", "plug-energy", "proactive-suggestions", "sensor-history"],
    );
    assert.equal(fresh.selection.enabledFeatures.includes("ai-assistant"), false, "AI stays out of a fresh install");
  });

  it("turns AI off on a fresh install and keeps upgrade users where they were", async () => {
    const fresh = mountApp(null);
    await settle();
    assert.equal(fresh.settings.aiAssistantEnabled, false, "fresh install starts with AI off");
    assert.equal(fresh.settings.proactiveSuggestionsEnabled, true, "suggestions still default on");
    assert.equal(isAiAssistantEnabled(fresh.settings), false);

    await closeTestWindow(dom);
    dom = mountTestWindow({ stubInterval: true });
    installCssEscape();

    // An upgrade: settings written by an older build, without either switch.
    const upgrade = mountApp({ connectionMode: "demo", hasCompletedOnboarding: true, autoCheckUpdates: false });
    await settle();
    assert.equal(upgrade.settings.aiAssistantEnabled, undefined, "no value is invented for an upgrade");
    assert.equal(isAiAssistantEnabled(upgrade.settings), true, "an upgrade keeps working AI");
    assert.equal(isProactiveSuggestionsEnabled(upgrade.settings), true, "and keeps its suggestions");

    await closeTestWindow(dom);
    dom = mountTestWindow({ stubInterval: true });
    installCssEscape();

    // An upgrade that had already switched AI on explicitly keeps it even without other data.
    const explicit = mountApp({ aiAssistantEnabled: true });
    await settle();
    assert.equal(explicit.settings.aiAssistantEnabled, true, "an explicit on is never overwritten");
  });

  it("changes nothing when the identity read fails (fail-closed)", async () => {
    const unreadable = mountApp(null);
    // Simulate the P4a-W uncertain path: the credential vault read fails during hydration.
    Object.defineProperty(unreadable, "credentialVault", {
      configurable: true,
      value: {
        load: async () => {
          throw new Error("credential manager unavailable");
        },
        didLastCredentialLoadFail: () => false,
      },
    });
    await unreadable.retryIdentityMigration();
    await settle();
    assert.equal(unreadable.settings.aiAssistantEnabled, undefined, "an uncertain read writes nothing");
    assert.equal(unreadable.settings.proactiveSuggestionsEnabled, undefined);

    await closeTestWindow(dom);
    dom = mountTestWindow({ stubInterval: true });
    installCssEscape();

    // Corrupt settings storage is the other uncertain path: the load error must block the default.
    localStorage.setItem(STORAGE_KEY, "{not json");
    const corrupt = mountApp(null);
    await settle();
    assert.equal(corrupt.settings.aiAssistantEnabled, undefined, "a settings read error writes nothing");
    assert.equal(isAiAssistantEnabled(corrupt.settings), true, "and startup keeps the legacy behavior");
  });
});

describe("P5b-W acceptance 3: the new wording ships in all three languages", () => {
  it("renders the 主动建议 switch label in zh-Hans, zh-Hant and en", () => {
    const expectations: Array<{ language: "zh-Hans" | "zh-Hant" | "en"; label: string }> = [
      { language: "zh-Hans", label: "主动建议" },
      { language: "zh-Hant", label: "主動建議" },
      { language: "en", label: "Proactive suggestions" },
    ];
    for (const { language, label } of expectations) {
      const app = mountDemoApp();
      setWindowFocused(true);
      setLanguage(language);
      app.activeSheet = "settings";
      app.render();
      const labelEl = document.querySelector<HTMLElement>('label[for="settings-proactive-enabled"]');
      assert.ok(labelEl, `${language}: switch label missing`);
      assert.equal(labelEl.textContent?.trim(), label);
      app.dispose();
    }
  });
});
