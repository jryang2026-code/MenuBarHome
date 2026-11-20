import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import {
  DEVICE_CATEGORY_IDS,
  DEVICE_CATEGORY_PRESETS,
  deviceCategoryForDevice,
  FEATURE_IDS,
  type DeviceCategoryID,
} from "../src/core/capabilityManifest.js";
import type { SafetySignalKind } from "../src/core/capabilityReferenceVerdict.js";
import {
  DEVICE_CATEGORY_SELECTION_MODES,
  deviceCategoryLabel,
  deviceCategorySelectionFor,
  deviceCategorySelectionMode,
  deviceCategorySelectionModeLabel,
  normalizeDeviceCategorySelection,
  sameDeviceCategories,
  toggleDeviceCategory,
} from "../src/core/deviceTypeSelection.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  previewDeviceCategorySelection,
  resolveMiAccountSelectionState,
  revalidateAfterMiAccountReenable,
  writeMiAccountSelectionMutation,
  type HostCapabilityContextInput,
  type MiAccountSelectionState,
} from "../src/core/miAccountControl.js";
import { AutomationRuleStore, createAutomationRule, executeAutomationRule } from "../src/core/automationEngine.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY, ScheduledCommandStore } from "../src/core/scheduledCommands.js";
import { setLanguage } from "../src/core/i18n.js";
import type { HomeScene, SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { buildHostCapabilityContext } from "../src/ui/cloudRefresh.js";
import { enqueueIncomingOpenUrl, getActiveRaycastBridgeTokenForHost, setRaycastIntegrationEnabled } from "../src/ui/speechGuard.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { scheduledCommandIdentity } from "../src/ui/scheduledCommands.js";

const HA_SCOPE = "ha:http://home.local:8123";

let dom: Window;

function el<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing element: ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  el(selector).click();
  await setImmediate();
}

const ALL_CATEGORIES: readonly DeviceCategoryID[] = [...DEVICE_CATEGORY_IDS];

function selection(overrides: Partial<MiAccountSelectionState["selection"]> = {}) {
  return {
    enabledConnections: ["home-assistant" as const],
    enabledConnectionScopes: [HA_SCOPE],
    enabledFeatures: [...FEATURE_IDS],
    enabledCategories: [...ALL_CATEGORIES],
    ...overrides,
  };
}

function selectionState(
  enabledCategories: readonly DeviceCategoryID[] = ALL_CATEGORIES,
  overrides: Partial<MiAccountSelectionState> = {},
): MiAccountSelectionState {
  return {
    mode: "explicit",
    selection: selection({ enabledCategories: [...enabledCategories] }),
    disabledAccountIds: new Set<string>(),
    pendingRevalidationAccountIds: new Set<string>(),
    disabledHaScopes: new Set<string>(),
    pendingRevalidationHaScopes: new Set<string>(),
    pausedQuickActionIds: new Set<string>(),
    knownDisabledDevices: [],
    knownDisabledScenes: [],
    knownDisabledHaDevices: [],
    knownDisabledHaScenes: [],
    persistIfMigrationReady: () => false,
    ...overrides,
  };
}

function light(id: string, name: string): SmartDevice {
  return {
    id, name, roomId: "room", roomName: "客厅", model: "yeelink.light.ceiling22", isOnline: true,
    kind: {
      kind: "light", entityId: `miot:${id}:2`, isOn: true, brightnessPercent: 50,
      colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [],
    },
  };
}

function leakSensor(id: string, name: string): SmartDevice {
  return {
    id, name, roomId: "room", roomName: "厨房", model: "lumi.sensor_wleak.aq1", isOnline: true,
    kind: { kind: "sensor", temperature: null, humidity: null, battery: 90, alertKind: "leak" },
  };
}

function plug(id: string, name: string): SmartDevice {
  return {
    id, name, roomId: "room", roomName: "玄关", model: "cuco.plug.cp1", isOnline: true,
    kind: {
      kind: "plug", switchEntityId: `miot:${id}:2`, isOn: true, powerWatts: 12,
      childLockEntityId: null, isChildLocked: false,
    },
  };
}

function context(devices: readonly SmartDevice[], scenes: readonly HomeScene[] = []): HostCapabilityContextInput {
  return {
    state: selectionState(),
    accounts: [],
    devices: [...devices],
    scenes: [...scenes],
    haBaseURL: "http://home.local:8123",
    haToken: "token",
    connectionMode: "homeAssistant",
    dualSourceEnabled: false,
  };
}

beforeEach(() => {
  dom = mountTestWindow();
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});

afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("P4b-W · device-type selection semantics", () => {
  it("keeps every type when a stored list cannot be read", () => {
    // An empty or unknown-only list is corruption, not a choice: hiding the whole home is never
    // what the picker can produce, so the caller keeps the value it already has.
    assert.equal(normalizeDeviceCategorySelection(undefined), null);
    assert.equal(normalizeDeviceCategorySelection("light"), null);
    assert.equal(normalizeDeviceCategorySelection([]), null);
    assert.equal(normalizeDeviceCategorySelection(["spaceship"]), null);
    assert.equal(normalizeDeviceCategorySelection(["light", 7]), null);
    assert.deepEqual(normalizeDeviceCategorySelection(["plug", "light"]), ["light", "plug"]);
    assert.deepEqual(normalizeDeviceCategorySelection(["light", "spaceship"]), ["light"]);
  });

  it("maps the three modes onto the shared presets and back", () => {
    assert.deepEqual([...DEVICE_CATEGORY_SELECTION_MODES], ["allSupportedTypes", "lightAndSwitch", "custom"]);
    assert.equal(deviceCategorySelectionMode(ALL_CATEGORIES), "allSupportedTypes");
    assert.equal(deviceCategorySelectionMode(["plug", "light"]), "lightAndSwitch");
    assert.equal(deviceCategorySelectionMode(["light", "cover"]), "custom");
    assert.deepEqual(deviceCategorySelectionFor("allSupportedTypes", ["light"]), [...ALL_CATEGORIES]);
    assert.deepEqual(deviceCategorySelectionFor("lightAndSwitch", ALL_CATEGORIES), [...DEVICE_CATEGORY_PRESETS.lightAndSwitch]);
    assert.deepEqual(deviceCategorySelectionFor("custom", ["cover", "light"]), ["light", "cover"]);
    // A custom list that cannot be read falls back to every type rather than hiding the home.
    assert.deepEqual(deviceCategorySelectionFor("custom", []), [...ALL_CATEGORIES]);
  });

  it("compares selections by membership, not order, and toggles in manifest order", () => {
    assert.equal(sameDeviceCategories(["plug", "light"], ["light", "plug", "light"]), true);
    assert.equal(sameDeviceCategories(["light"], ["light", "plug"]), false);
    assert.deepEqual(toggleDeviceCategory(["cover"], "light"), ["light", "cover"]);
    assert.deepEqual(toggleDeviceCategory(["light", "cover"], "light"), ["cover"]);
  });

  it("labels every type and mode in all three languages", () => {
    assert.equal(deviceCategoryLabel("valve", "zh-Hans"), "阀门");
    assert.equal(deviceCategoryLabel("valve", "zh-Hant"), "閥門");
    assert.equal(deviceCategoryLabel("valve", "en"), "Valves");
    assert.equal(deviceCategorySelectionModeLabel("lightAndSwitch", "zh-Hans"), "只用灯和开关");
    assert.equal(deviceCategorySelectionModeLabel("lightAndSwitch", "zh-Hant"), "只用燈和開關");
    assert.equal(deviceCategorySelectionModeLabel("lightAndSwitch", "en"), "Only Lights & Switches");
  });
});

describe("P4b-W · impact preview reuses the P2b verdict engine", () => {
  const sensor = leakSensor("sensor.kitchen_leak", "厨房漏水传感器");
  const lamp = light("light.entry", "玄关灯");
  const socket = plug("plug.heater", "取暖器插座");

  /** Real stores, so the preview assembles references exactly as production does. */
  function stores(options: {
    readonly timers?: readonly { readonly id: string; readonly name: string; readonly targetId: string }[];
    readonly rules?: readonly { readonly id: string; readonly targetId: string }[];
  } = {}): { readonly scheduledCommandStore: ScheduledCommandStore; readonly ruleStore: AutomationRuleStore } {
    const data = new Map<string, string>();
    data.set(SCHEDULED_COMMANDS_STORAGE_KEY, JSON.stringify({
      version: 1,
      sources: [{
        identity: HA_SCOPE,
        scheduledCommands: (options.timers ?? []).map((timer) => ({
          id: timer.id, command: timer.name, reply: "好", delaySeconds: 600,
          fireTimestampMs: Date.now() + 600_000,
          intents: [{ targetId: timer.targetId, operation: { kind: "power", isOn: false } }],
          sourceScopes: [HA_SCOPE],
        })),
        missedScheduledCommands: [],
      }],
    }));
    const rules = (options.rules ?? []).map((rule) => createAutomationRule({
      id: rule.id, trigger: "away", action: { kind: "devices", deviceIds: [rule.targetId], isOn: false }, isEnabled: true,
    }));
    return {
      scheduledCommandStore: new ScheduledCommandStore({
        getItem: (key) => data.get(key) ?? null,
        setItem: (key, value) => { data.set(key, value); },
      }),
      ruleStore: { load: () => rules } as unknown as AutomationRuleStore,
    };
  }

  it("names the cards that hide and the alert reads that stay", () => {
    const preview = previewDeviceCategorySelection({
      proposedCategories: ALL_CATEGORIES.filter((id) => id !== "sensor"),
      context: context([sensor, lamp]),
      scheduledCommandStore: stores().scheduledCommandStore,
      activeTimerIdentity: HA_SCOPE,
      ruleStore: stores().ruleStore,
      safetyPolicy: { enabledSignals: ["leak"] as readonly SafetySignalKind[] },
    });
    assert.deepEqual(preview.hiddenCards.map((card) => card.id), [sensor.id]);
    // The leak alert keeps reading the hidden sensor: it never becomes a card or a control target.
    assert.deepEqual(preview.retainedSafetyCards.map((card) => card.id), [sensor.id]);
    assert.deepEqual([...preview.retainedSafetySignals], ["leak"]);
    assert.ok(preview.verdict.softNotices.some((notice) => notice.kind === "safetyReadsRetained"));
    assert.deepEqual(preview.affectedReferences, []);
  });

  it("drops the sensor once its alert is off", () => {
    const preview = previewDeviceCategorySelection({
      proposedCategories: ALL_CATEGORIES.filter((id) => id !== "sensor"),
      context: context([sensor, lamp]),
      scheduledCommandStore: stores().scheduledCommandStore,
      activeTimerIdentity: HA_SCOPE,
      ruleStore: stores().ruleStore,
      safetyPolicy: { enabledSignals: [] },
    });
    assert.deepEqual(preview.hiddenCards.map((card) => card.id), [sensor.id]);
    assert.deepEqual([...preview.retainedSafetyCards], []);
    assert.deepEqual([...preview.retainedSafetySignals], []);
    assert.equal(preview.verdict.softNotices.some((notice) => notice.kind === "safetyReadsRetained"), false);
  });

  it("lists the timers, automations and quick actions that point at a hidden type", () => {
    const { scheduledCommandStore, ruleStore } = stores({
      timers: [{ id: "timer_1", name: "10 分钟后关玄关灯", targetId: lamp.id }],
      rules: [{ id: "rule_1", targetId: lamp.id }],
    });
    const scene: HomeScene = { id: "scene.movie", name: "观影模式", entityId: "scene.movie" };
    const preview = previewDeviceCategorySelection({
      proposedCategories: ALL_CATEGORIES.filter((id) => id !== "light"),
      context: context([lamp, socket], [scene]),
      scheduledCommandStore,
      activeTimerIdentity: HA_SCOPE,
      ruleStore,
      safetyPolicy: { enabledSignals: [] },
    });
    const kinds = preview.affectedReferences.map((item) => item.kind).sort();
    // 全屋关灯 and 柔和夜灯 both target lights, so closing the light type pauses both.
    assert.deepEqual(kinds, ["automationRule", "quickAction", "quickAction", "waitingTimer"]);
    assert.ok(preview.affectedReferences.some((item) => item.name === "10 分钟后关玄关灯"));
    // Manual scenes stay usable and say so instead of being silently scoped down.
    assert.ok(preview.verdict.softNotices.some((notice) => notice.kind === "manualScenesMayControlHiddenDevices"));
    assert.equal(preview.verdict.disposition, "requiresPauseConfirmation");
    assert.equal(preview.verdict.canDeactivate, true);
  });

  it("counts the plug card as a light-and-switch member, not a hidden one", () => {
    const preview = previewDeviceCategorySelection({
      proposedCategories: [...DEVICE_CATEGORY_PRESETS.lightAndSwitch],
      context: context([lamp, socket]),
      scheduledCommandStore: stores().scheduledCommandStore,
      activeTimerIdentity: HA_SCOPE,
      ruleStore: stores().ruleStore,
      safetyPolicy: { enabledSignals: [] },
    });
    assert.deepEqual(preview.hiddenCards, []);
    assert.equal(deviceCategoryForDevice(socket), "plug");
    assert.deepEqual([...preview.proposedCategories], ["light", "plug"]);
  });
});

describe("P4b-W · persistence", () => {
  it("stores the choice beside the connection selection and reads it back", () => {
    assert.equal(writeMiAccountSelectionMutation({
      mutate: (prev) => ({ ...prev, extraFields: { ...prev.extraFields, enabledCategories: ["light", "plug"] } }),
    }), true);
    const state = resolveMiAccountSelectionState({ accounts: [], connectionMode: "demo", hasExistingPreferences: true });
    assert.deepEqual(state.selection.enabledCategories, ["light", "plug"]);
    assert.equal(state.mode, "explicit");
  });

  it("keeps every type when the stored list is empty or unreadable", () => {
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify({
      schemaVersion: 1, migrationComplete: true, disabledMiAccountIds: [], enabledCategories: [],
    }));
    const state = resolveMiAccountSelectionState({ accounts: [], connectionMode: "demo", hasExistingPreferences: true });
    assert.deepEqual(state.selection.enabledCategories, [...ALL_CATEGORIES].sort());
  });

  it("removes the key again when every type is chosen, so the record stays 'never chose'", () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }));
    const app = new MenuMijiaWindowsApp(el("#app"));
    assert.equal(app.setEnabledDeviceCategories(["light", "plug"]), true);
    assert.deepEqual(
      (JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as { enabledCategories?: unknown }).enabledCategories,
      ["light", "plug"],
    );
    assert.equal(app.setEnabledDeviceCategories(ALL_CATEGORIES), true);
    assert.equal(
      (JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as Record<string, unknown>).enabledCategories,
      undefined,
    );
    // An unreadable list is refused outright: nothing is written over a value the app cannot trust.
    assert.equal(app.setEnabledDeviceCategories([]), false);
  });
});

describe("P4b-W · Settings and the guide share one block", () => {
  /** How many type checkboxes the block renders as checked (the 自己选 list only). */
function emailCheckedCount(): number {
  return [...document.querySelectorAll<HTMLInputElement>("[data-device-type-category]")].filter((input) => input.checked).length;
}

function startDemo(): MenuMijiaWindowsApp {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }));
    return new MenuMijiaWindowsApp(el("#app"));
  }

  it("offers all three choices with every type applied by default", async () => {
    startDemo();
    await click("#btn-settings");
    const block = el("[data-device-types]");
    assert.equal(block.querySelectorAll("[data-device-type-mode]").length, 3);
    assert.equal(el('[data-device-type-mode="allSupportedTypes"]').getAttribute("aria-pressed"), "true");
    assert.equal(el('[data-device-type-mode="lightAndSwitch"]').getAttribute("aria-pressed"), "false");
    // Nothing to apply until the user actually changes something.
    assert.equal(document.querySelector("[data-device-type-apply]"), null);
    assert.equal(document.querySelector("[data-device-type-categories]"), null);
    assert.match(block.textContent ?? "", /全部已支持类型/);
    assert.match(block.textContent ?? "", /只用灯和开关/);
    assert.match(block.textContent ?? "", /自己选/);
    assert.match(block.textContent ?? "", /仍会读取部分隐藏设备/);
  });

  it("previews the change before writing and masks only the unselected types", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="lightAndSwitch"]');

    const preview = el("[data-device-type-preview]").textContent ?? "";
    assert.match(preview, /5 张卡片/);
    assert.match(preview, /低电量/);
    // Closing the camera type is rendered as the feature that turns off with it, not "子功能".
    assert.match(preview, /摄像机实况也会一并停用/);
    assert.equal(document.querySelector("[data-device-type-apply]") !== null, true);

    await click("[data-device-type-apply]");
    assert.deepEqual(
      JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}").enabledCategories,
      ["light", "plug"],
    );
    // The demo home is synthesized locally, so the selection re-derives its cards right away.
    assert.deepEqual(app.devices.map((device) => deviceCategoryForDevice(device)).sort(), ["light", "light", "plug"]);
    assert.match(el("[data-device-type-status]").textContent ?? "", /已应用/);
    assert.ok(document.activeElement === el("[data-device-type-status]"), "focus lands on the applied status");
    assert.equal(document.querySelector("[data-device-type-apply]"), null, "nothing left to apply");
  });

  it("lets 自己选 uncheck one type, and 取消 puts the stored value back", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="custom"]');
    assert.equal(document.querySelectorAll("[data-device-type-category]").length, ALL_CATEGORIES.length);
    const camera = el<HTMLInputElement>('[data-device-type-category="camera"]');
    assert.equal(camera.checked, true);
    camera.click();
    await setImmediate();
    assert.equal(el<HTMLInputElement>('[data-device-type-category="camera"]').checked, false);
    assert.ok(
      document.activeElement === el('[data-device-type-category="camera"]'),
      "focus stays on the checkbox that just changed",
    );
    assert.match(el("[data-device-type-preview]").textContent ?? "", /摄像机/);

    await click("[data-device-type-cancel]");
    assert.equal(document.querySelector("[data-device-type-apply]"), null);
    // 取消 writes nothing: the record carries no device-type list, which still means every type.
    assert.equal(
      (JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as Record<string, unknown>).enabledCategories,
      undefined,
    );
    assert.equal(el('[data-device-type-mode="allSupportedTypes"]').getAttribute("aria-pressed"), "true");
  });

  it("keeps the 自己选 list open and checked after a custom list is applied", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="custom"]');
    el<HTMLInputElement>('[data-device-type-category="camera"]').click();
    await setImmediate();
    await click("[data-device-type-apply]");

    assert.deepEqual(
      (JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as { enabledCategories?: unknown }).enabledCategories,
      ALL_CATEGORIES.filter((id) => id !== "camera"),
    );
    // Reopening the block shows the stored custom list, not a mode pill with no list under it.
    assert.equal(document.querySelectorAll("[data-device-type-category]").length, ALL_CATEGORIES.length);
    assert.equal(el<HTMLInputElement>('[data-device-type-category="camera"]').checked, false);
    assert.equal(el('[data-device-type-mode="custom"]').getAttribute("aria-pressed"), "true");
  });

  it("refuses to uncheck the last remaining type instead of silently selecting every type", async () => {
    startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="custom"]');
    for (const category of ALL_CATEGORIES) {
      if (category === "light") continue;
      el<HTMLInputElement>(`[data-device-type-category="${category}"]`).click();
      await setImmediate();
    }
    assert.equal(emailCheckedCount(), 1);
    el<HTMLInputElement>('[data-device-type-category="light"]').click();
    await setImmediate();

    // The draft keeps its one type, the checkbox stays checked and the reason is announced.
    assert.equal(emailCheckedCount(), 1);
    assert.equal(el<HTMLInputElement>('[data-device-type-category="light"]').checked, true);
    assert.match(el("[data-device-type-error]").textContent ?? "", /至少要保留一个设备类型/);
    assert.ok(document.activeElement === el("[data-device-type-error]"), "focus lands on the refusal");
    // The same list still responds: re-checking a type adds it back to the draft.
    el<HTMLInputElement>('[data-device-type-category="plug"]').click();
    await setImmediate();
    assert.equal(emailCheckedCount(), 2);
    assert.equal(document.querySelector("[data-device-type-error]"), null, "the refusal clears on the next edit");
  });

  it("keeps climateSleepOff paused with fan enabled until climate is restored and revalidated", async () => {
    const app = startDemo();
    const ruleStore = new AutomationRuleStore();
    const rule = createAutomationRule({
      id: "sleep_off", trigger: "away", action: { kind: "quickAction", quickAction: "climateSleepOff" }, isEnabled: true,
    });
    assert.equal(ruleStore.save([rule]), true);
    await click("#btn-settings");
    await click('[data-device-type-mode="custom"]');
    await click('[data-device-type-category="climate"]');
    await click("[data-device-type-apply]");
    assert.equal(revalidateAfterMiAccountReenable({
      context: buildHostCapabilityContext(app),
      scheduledCommandStore: app.scheduledCommandStore,
      activeTimerIdentity: scheduledCommandIdentity(app.settings),
      ruleStore,
    }), true);
    const [paused] = ruleStore.load();
    assert.equal(paused?.isEnabled, false);
    assert.ok(paused.pausedByCapabilities?.includes("climate"));
    assert.match(app.evaluateAutomationRuleWriteGate(paused) ?? "", /停用|关闭/);
    assert.equal(await executeAutomationRule(app, paused), null);
    await click('[data-device-type-mode="allSupportedTypes"]');
    await click("[data-device-type-apply]");
    assert.equal(ruleStore.load()[0]?.isEnabled, true);
    assert.equal(ruleStore.load()[0]?.pausedByCapabilities, undefined);
  });

  it("persists lightsOff pause and rejects both voice and URL execution", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="custom"]');
    await click('[data-device-type-category="light"]');
    await click("[data-device-type-apply]");
    assert.ok(JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}").pausedQuickActionIds.includes("lightsOff"));
    await app.handleNaturalCommand("quick:lightsOff");
    assert.match(app.replyBanner?.text ?? "", /全屋关灯.*已暂停/);
    app.replyBanner = null;
    setRaycastIntegrationEnabled(app, true);
    const token = getActiveRaycastBridgeTokenForHost(app);
    assert.ok(token);
    await enqueueIncomingOpenUrl(app, `menumijia://scene?name=quick%3AlightsOff&token=${encodeURIComponent(token)}&id=paused-lights`);
    assert.match((app.replyBanner as { text: string } | null)?.text ?? "", /全屋关灯.*已暂停/);
  });

  for (const failingKey of [AutomationRuleStore.storageKey, MI_ACCOUNT_CAPABILITY_STORAGE_KEY]) {
    it(`rolls back the timer and rule when ${failingKey} cannot be written`, async () => {
      const app = startDemo();
      const identity = scheduledCommandIdentity(app.settings);
      const queue = app.scheduledCommandStore.queue(identity);
      queue.scheduledCommands = [{
        id: "timer_cool_down", command: "10 分钟后关空调", reply: "好", delaySeconds: 600,
        fireTimestampMs: Date.now() + 600_000,
        intents: [{ targetId: "climate.living_ac", operation: { kind: "power", isOn: false } }],
      }];
      assert.equal(app.scheduledCommandStore.persist(), true);

      const ruleStore = new AutomationRuleStore();
      const rule = createAutomationRule({
        id: "rule_cool_down", trigger: "away", action: { kind: "quickAction", quickAction: "climateSleepOff" }, isEnabled: true,
      });
      assert.equal(ruleStore.save([rule]), true);
      await click("#btn-settings");
      await click('[data-device-type-mode="lightAndSwitch"]');
      assert.match(el("[data-device-type-preview]").textContent ?? "", /10 分钟后关空调/);

      const before = [SCHEDULED_COMMANDS_STORAGE_KEY, AutomationRuleStore.storageKey, MI_ACCOUNT_CAPABILITY_STORAGE_KEY]
        .map((key) => localStorage.getItem(key));
      const originalSetItem = localStorage.setItem.bind(localStorage);
      Object.defineProperty(localStorage, "setItem", {
        configurable: true,
        writable: true,
        value: (key: string, value: string): void => {
          if (key === failingKey) throw new Error("QuotaExceededError");
          originalSetItem(key, value);
        },
      });
      try {
        await click("[data-device-type-apply]");
        assert.match(el("[data-device-type-error]").textContent ?? "", /保持原样/);
        // The live store is what keeps running, so it must be back too — not only the stored copy.
        const live = app.scheduledCommandStore.queue(identity);
        assert.deepEqual(live.scheduledCommands.map((item) => item.id), ["timer_cool_down"]);
        assert.deepEqual(live.pausedScheduledCommands ?? [], []);
        assert.equal(app.cameraLive.cameraCategoryEnabled, true);
        assert.deepEqual([SCHEDULED_COMMANDS_STORAGE_KEY, AutomationRuleStore.storageKey, MI_ACCOUNT_CAPABILITY_STORAGE_KEY]
          .map((key) => localStorage.getItem(key)), before);
      } finally {
        Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: originalSetItem });
      }
    });

  }

  it("reports a store that refuses the write, keeps the old choice and focuses the message", async () => {
    const app = startDemo();
    await click("#btn-settings");
    await click('[data-device-type-mode="lightAndSwitch"]');
    const originalSetItem = localStorage.setItem.bind(localStorage);
    const blocked = (key: string): boolean => key === MI_ACCOUNT_CAPABILITY_STORAGE_KEY;
    Object.defineProperty(localStorage, "setItem", {
      configurable: true,
      writable: true,
      value: (key: string, value: string): void => {
        if (blocked(key)) throw new Error("QuotaExceededError");
        originalSetItem(key, value);
      },
    });
    try {
      await click("[data-device-type-apply]");
      const banner = el("[data-device-type-error]");
      assert.match(banner.textContent ?? "", /暂时无法保存/);
      assert.ok(document.activeElement === banner, "focus lands on the failure message");
      assert.equal(document.querySelector("[data-device-type-apply]") !== null, true, "the draft stays for a retry");
      assert.equal(app.devices.length, 8, "no card changed");
    } finally {
      Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: originalSetItem });
    }
    await click("[data-device-type-apply]");
    assert.match(el("[data-device-type-status]").textContent ?? "", /已应用/);
  });

  it("renders the same block in the first-run guide once a platform is chosen", async () => {
    new MenuMijiaWindowsApp(el("#app"));
    await setImmediate();
    assert.equal(document.querySelector('[data-onboarding-device-types]'), null, "nothing to trim before a platform");
    await click('[data-onboarding-card="demo"]');
    assert.ok(document.querySelector("[data-onboarding-step=\"3\"] [data-device-types]"), "the type step appears with the demo home");
    await click('[data-onboarding-step="3"] [data-device-type-mode="lightAndSwitch"]');
    await click('[data-onboarding-step="3"] [data-device-type-apply]');
    assert.deepEqual(
      JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}").enabledCategories,
      ["light", "plug"],
    );
  });

  it("marks every enabled source for revalidation, so turning a type back on resumes what it paused", () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      connectionMode: "homeAssistant",
      haBaseURL: "http://home.local:8123",
      haToken: "token",
      hasCompletedOnboarding: true,
    }));
    const app = new MenuMijiaWindowsApp(el("#app"));
    assert.equal(app.setEnabledDeviceCategories(["light", "plug"]), true);
    const record = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as {
      pendingRevalidationHaScopes?: unknown;
    };
    assert.equal(record.pendingRevalidationHaScopes, undefined);
    assert.equal(app.setEnabledDeviceCategories(ALL_CATEGORIES), true);
    assert.deepEqual(JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}").pendingRevalidationHaScopes, [HA_SCOPE]);
  });

  it("keeps the demo home on the stored selection after a restart", () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }));
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify({
      schemaVersion: 1, migrationComplete: true, disabledMiAccountIds: [], enabledCategories: ["light", "plug"],
    }));
    const app = new MenuMijiaWindowsApp(el("#app"));
    assert.deepEqual(app.devices.map((device) => deviceCategoryForDevice(device)).sort(), ["light", "light", "plug"]);
  });

  it("switches the block's copy with the interface language", async () => {
    const app = startDemo();
    await click("#btn-settings");
    setLanguage("zh-Hant");
    // Changing the interface language re-renders the sheet in production; do the same here.
    app.render();
    await setImmediate();
    assert.match(el("[data-device-types]").textContent ?? "", /只用燈和開關/);
    assert.match(el("[data-device-types]").textContent ?? "", /全部已支援類型/);
    setLanguage("en");
    app.render();
    await setImmediate();
    assert.match(el("[data-device-types]").textContent ?? "", /Only Lights & Switches/);
    assert.match(el("[data-device-types]").textContent ?? "", /All Supported Types/);
  });
});
