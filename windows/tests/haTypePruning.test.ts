import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import {
  evaluateControlTargetGate, evaluatePlanTargetsGate,
  type CapabilityIndexedDevice, type CapabilitySelection, type SafetySignalKind,
} from "../src/core/capabilityReferenceVerdict.js";
import { DEVICE_CATEGORY_IDS, type DeviceCategoryID } from "../src/core/capabilityManifest.js";
import { DualSourceCoordinator } from "../src/core/dualSourceProvider.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import {
  buildHaTypePrunePlan, haAuxiliarySafetySignals, haSafetySignalsForDevice, haTypePruningActive,
} from "../src/core/haTypePruning.js";
import { miotSafetySignalsForPrefs, miotSafetySignalsForSensorPolicy } from "../src/core/miotTypePruning.js";
import { safetySignalsForPrefs, safetySignalsForSensorPolicy } from "../src/core/safetySignalPolicy.js";
import { createDefaultSensorAlertPolicy } from "../src/core/safetyAndHealth.js";
import {
  buildIndexedCapabilityDevices, evaluateDisabledDeviceUrlGate, evaluateDeviceEntityWriteGate,
  evaluateIntentsWriteGate, previewDeviceCategorySelection, resolveMiAccountSelectionState,
} from "../src/core/miAccountControl.js";
import { AutomationRuleStore } from "../src/core/automationEngine.js";
import { ScheduledCommandStore } from "../src/core/scheduledCommands.js";
import {
  applyHaTypePruneSnapshot, buildHostCapabilityContext, haTypePruneSnapshotIsCurrent, hiddenTypeDevices,
  safetyRetainedHADeviceFacets, safetyRetainedHADevices,
} from "../src/ui/cloudRefresh.js";
import type { SmartDevice } from "../src/core/models.js";

const HA_URL = "https://ha.example.test:8123";
const HA_TOKEN = "{{SECRET_9hgbk4mmn}}";
const SCOPE = "ha:https://ha.example.test:8123";
const ALL_SENSOR_SIGNALS: readonly SafetySignalKind[] = ["leak", "smoke", "gas", "contact", "motion", "vibration", "lock"];

function selection(categories: readonly DeviceCategoryID[], scopes: readonly string[] = [SCOPE]): CapabilitySelection {
  return {
    enabledConnections: ["home-assistant"],
    enabledConnectionScopes: [...scopes],
    enabledFeatures: [],
    enabledCategories: [...categories],
  };
}

// One registry group per card kind the plan must tell apart, with the signal each one carries.
const snapshot = {
  areas: [{ area_id: "living", name: "客厅" }],
  devices: [
    { id: "d-light", name: "客厅灯", area_id: "living", model: "test.light" },
    { id: "d-climate", name: "客厅空调", area_id: "living", model: "test.climate" },
    { id: "d-plug", name: "电暖器插座", area_id: "living", model: "test.plug" },
    { id: "d-leak", name: "厨房水浸", area_id: "living", model: "test.leak" },
    { id: "d-smoke", name: "烟雾报警", area_id: "living", model: "test.smoke" },
    { id: "d-lock", name: "入户门锁", area_id: "living", model: "test.lock" },
    { id: "d-contact", name: "阳台门窗", area_id: "living", model: "test.contact" },
    { id: "d-cover", name: "客厅窗帘", area_id: "living", model: "test.cover" },
    { id: "d-valve", name: "燃气阀", area_id: "living", model: "tuya.valve" },
    { id: "d-gas", name: "燃气关断阀", area_id: "living", model: "tuya.valve" },
  ],
  entities: [
    { entity_id: "light.living", device_id: "d-light" },
    { entity_id: "climate.living", device_id: "d-climate" },
    { entity_id: "switch.heater", device_id: "d-plug" },
    { entity_id: "binary_sensor.leak", device_id: "d-leak" },
    { entity_id: "binary_sensor.smoke", device_id: "d-smoke" },
    { entity_id: "lock.front_door", device_id: "d-lock" },
    { entity_id: "binary_sensor.door", device_id: "d-contact" },
    { entity_id: "cover.living", device_id: "d-cover" },
    { entity_id: "valve.gas_main", device_id: "d-valve" },
    // An auxiliary alarm row: the card is a valve, the gas alert arrives as a 更多设置 facet.
    { entity_id: "valve.gas_shutoff", device_id: "d-gas" },
    { entity_id: "binary_sensor.gas_leak", device_id: "d-gas" },
    { entity_id: "scene.movie" },
    { entity_id: "script.leaving" },
  ],
  states: [
    { entity_id: "light.living", state: "on", attributes: { friendly_name: "客厅灯" } },
    {
      entity_id: "climate.living",
      state: "cool",
      attributes: {
        friendly_name: "客厅空调", hvac_modes: ["cool", "heat", "off"],
        temperature: 25, current_temperature: 27, min_temp: 16, max_temp: 30,
      },
    },
    { entity_id: "switch.heater", state: "off", attributes: { friendly_name: "电暖器插座", device_class: "outlet" } },
    { entity_id: "binary_sensor.leak", state: "off", attributes: { friendly_name: "厨房水浸", device_class: "moisture" } },
    { entity_id: "binary_sensor.smoke", state: "off", attributes: { friendly_name: "烟雾报警", device_class: "smoke" } },
    { entity_id: "lock.front_door", state: "locked", attributes: { friendly_name: "入户门锁" } },
    { entity_id: "binary_sensor.door", state: "off", attributes: { friendly_name: "阳台门窗", device_class: "door" } },
    {
      entity_id: "cover.living",
      state: "open",
      attributes: { friendly_name: "客厅窗帘", current_position: 40, supported_features: 15 },
    },
    { entity_id: "valve.gas_main", state: "closed", attributes: { friendly_name: "燃气阀", device_class: "gas" } },
    { entity_id: "valve.gas_shutoff", state: "closed", attributes: { friendly_name: "燃气关断阀", device_class: "gas" } },
    { entity_id: "binary_sensor.gas_leak", state: "off", attributes: { friendly_name: "燃气泄漏", device_class: "gas" } },
    { entity_id: "scene.movie", state: "scenic", attributes: { friendly_name: "影院模式" } },
    { entity_id: "script.leaving", state: "off", attributes: { friendly_name: "离家" } },
  ],
};

const unpruned = HomeAssistantSynthesizer.synthesizeWithPrune(snapshot, null);
const cards = unpruned.home.devices;
const card = (id: string): SmartDevice => {
  const found = cards.find((device) => device.id === id);
  assert.ok(found, `fixture card ${id}`);
  return found;
};

function splitWith(
  categories: readonly DeviceCategoryID[],
  safetySignals: readonly SafetySignalKind[] = [],
  extra: { readonly starredDeviceIds?: readonly string[]; readonly scopes?: readonly string[] } = {},
) {
  return HomeAssistantSynthesizer.synthesizeWithPrune(snapshot, {
    prune: {
      selection: selection(categories, extra.scopes ?? [SCOPE]),
      connectionScope: SCOPE,
      safetySignals,
      ...(extra.starredDeviceIds ? { starredDeviceIds: extra.starredDeviceIds } : {}),
    },
  });
}

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string): string | null => map.get(key) ?? null,
    setItem: (key: string, value: string): void => { map.set(key, value); },
    removeItem: (key: string): void => { map.delete(key); },
  };
}

describe("Home Assistant device-type pruning (P3b-W)", () => {
  it("draws exactly what it drew before when every type is enabled or the connection is off", () => {
    for (const fixture of ["ha_snapshot.json", "ha_domain_cards.json", "ha_cover_snapshot.json", "ha_regressions.json"]) {
      const raw = JSON.parse(readFileSync(resolve(process.cwd(), "../Tests/Fixtures", fixture), "utf8")) as unknown;
      const before = HomeAssistantSynthesizer.synthesize(raw);
      for (const prune of [
        { selection: selection(DEVICE_CATEGORY_IDS), connectionScope: SCOPE, safetySignals: ALL_SENSOR_SIGNALS },
        // A scope that is off, or still being migrated, is equally unpruned.
        { selection: selection(["light"], ["ha:https://other.example.test"]), connectionScope: SCOPE, safetySignals: [] },
      ]) {
        const after = HomeAssistantSynthesizer.synthesizeWithPrune(raw, { prune });
        assert.equal(after.prunePlan, null, `${fixture}: nothing pruned`);
        assert.deepEqual(after.home, before, fixture);
        assert.deepEqual(after.safetyDevices, [], fixture);
        assert.deepEqual(after.hiddenIndexedDevices, [], fixture);
      }
    }
    assert.deepEqual(cards.map((device) => device.id), [
      "d-light", "d-climate", "d-plug", "d-leak", "d-smoke", "d-lock", "d-contact", "d-cover", "d-valve", "d-gas",
    ]);
    const leakKind = card("d-leak").kind, lockKind = card("d-lock").kind;
    assert.equal(leakKind.kind === "sensor" ? leakKind.alertKind : undefined, "leak");
    assert.equal(lockKind.kind === "sensor" ? lockKind.alertKind : undefined, "lock");
  });

  it("withholds a closed type from cards, facets and environment readings", () => {
    const pruned = splitWith(["climate"]);
    assert.ok(pruned.prunePlan);
    assert.deepEqual(pruned.home.devices.map((device) => device.id), ["d-climate"]);
    // The light had facets in the unpruned home; nothing of it survives into the drawn snapshot, and
    // only the drawn card can still contribute an environment reading.
    assert.equal(Object.hasOwn(pruned.home.deviceFacets ?? {}, "d-light"), false);
    assert.deepEqual(pruned.home.environmentReadings.map((reading) => reading.id), ["d-climate"]);
    assert.deepEqual(pruned.home.rooms.map((room) => [room.id, room.deviceCount]), [["living", 1]]);
    // Every withheld card keeps an identity entry, so the gate can name its type.
    assert.deepEqual(pruned.hiddenIndexedDevices.map((device) => device.id).sort(), [
      "d-contact", "d-cover", "d-gas", "d-leak", "d-light", "d-lock", "d-plug", "d-smoke", "d-valve",
    ]);
    const lightIndex = pruned.hiddenIndexedDevices.find((device) => device.id === "d-light");
    assert.equal(lightIndex?.category, "light");
    assert.equal(lightIndex?.connection, "home-assistant");
    assert.equal(lightIndex?.sourceScope, SCOPE);
  });

  it("keeps exactly the closed cards whose own alert is still on", () => {
    // A leak alert keeps the leak sensor and nothing else, even though four sensors are closed.
    const leakOnly = splitWith(["light"], ["leak"]);
    assert.deepEqual(leakOnly.safetyDevices.map((device) => device.id), ["d-leak"]);
    assert.deepEqual(leakOnly.home.devices.map((device) => device.id), ["d-light"]);
    const retainedKind = leakOnly.safetyDevices[0]!.kind;
    assert.equal(retainedKind.kind === "sensor" ? retainedKind.alertKind : undefined, "leak");
    // Consecutive switches are independent, and with no alert on nothing is kept.
    assert.deepEqual(splitWith(["light"], ["smoke"]).safetyDevices.map((device) => device.id), ["d-smoke"]);
    assert.deepEqual(splitWith(["light"], []).safetyDevices, []);
  });

  it("previews the auxiliary gas alarm retained by the prune plan, including a merged card", async () => {
    const host = {
      settings: { haBaseURL: HA_URL, haToken: HA_TOKEN, connectionMode: "homeAssistant" },
      devices: cards, haTypePruneScope: null, haTypeSafetySignals: {},
    };
    applyHaTypePruneSnapshot(host, { scope: SCOPE, safetySignalsByDeviceId: unpruned.safetySignalsByDeviceId });
    const storage = memoryStorage();
    const previewFor = (context: ReturnType<typeof buildHostCapabilityContext>) => previewDeviceCategorySelection({
      context, proposedCategories: ["light"],
      scheduledCommandStore: new ScheduledCommandStore(storage), activeTimerIdentity: null,
      ruleStore: new AutomationRuleStore(storage), safetyPolicy: { enabledSignals: ["gas"] },
    });
    const preview = previewFor(buildHostCapabilityContext(host));
    assert.deepEqual(preview.retainedSafetyCards.map((device) => device.id), ["d-gas"]);
    assert.deepEqual(preview.retainedSafetyCards.map((device) => device.id), splitWith(["light"], ["gas"]).safetyDevices.map((device) => device.id));
    assert.deepEqual(preview.retainedSafetySignals, ["gas"]);

    const coordinator = new DualSourceCoordinator(null);
    coordinator.canonical.assign("merged-gas", ["ha:d-gas"]);
    const { merged } = await coordinator.refreshParallel({
      fetchHA: async () => ({ home: unpruned.home }), fetchMi: async () => null,
    });
    const mergedPreview = previewFor(buildHostCapabilityContext({
      ...host, devices: merged.home.devices, dualSourceCoordinator: coordinator,
      settings: { ...host.settings, dualSourceEnabled: true, miSession: { userId: "account", region: "cn" } },
    }, []));
    assert.deepEqual(mergedPreview.retainedSafetyCards.map((device) => device.id), ["merged-gas"]);
    assert.deepEqual(mergedPreview.retainedSafetySignals, ["gas"]);
  });

  it("reads the shared 安全与提醒 switches, with the sensor alerts outside the master switch", () => {
    const policy = createDefaultSensorAlertPolicy();
    const prefs = {
      enableSafetyAlerts: true, longRunningPlug: true, longRunningClimate: true,
      lowBattery: true, favoriteOffline: true,
    };
    // Both platforms share one mapping; the Mi module re-exports these functions verbatim.
    assert.equal(miotSafetySignalsForPrefs, safetySignalsForPrefs);
    assert.equal(miotSafetySignalsForSensorPolicy, safetySignalsForSensorPolicy);
    for (const kind of ["longRunningPlug", "highPower", "longRunningClimate", "lowBattery", "starredOffline"] as const) {
      assert.ok(safetySignalsForPrefs(prefs, policy).includes(kind), kind);
    }
    // The sensor alerts have their own switches and default on, so the actuator signals are isolated
    // here: a closed plug keeps its power draw, a closed air conditioner needs its own switch.
    assert.deepEqual(splitWith([], ["longRunningPlug", "highPower"]).safetyDevices.map((d) => d.id), ["d-plug"]);
    assert.deepEqual(splitWith([], ["longRunningClimate"]).safetyDevices.map((d) => d.id), ["d-climate"]);
    const plugSwitchOff = safetySignalsForPrefs(
      { enableSafetyAlerts: true, longRunningPlug: false, longRunningClimate: true, lowBattery: false, favoriteOffline: false },
      policy,
    );
    assert.equal(plugSwitchOff.includes("longRunningPlug"), false);
    assert.equal(splitWith([], plugSwitchOff).safetyDevices.some((device) => device.id === "d-plug"), false);
    // The master switch does not gate them: smoke and lock keep reading while it is off.
    assert.ok(safetySignalsForSensorPolicy(policy).includes("smoke"));
    assert.ok(safetySignalsForSensorPolicy(policy).includes("lock"));
  });

  it("derives each card's own signals, and keeps a pinned card only for its offline alert", () => {
    assert.deepEqual(haSafetySignalsForDevice(card("d-leak")), ["leak"]);
    assert.deepEqual(haSafetySignalsForDevice(card("d-lock")), ["lock"]);
    assert.deepEqual(haSafetySignalsForDevice(card("d-contact")), ["contact"]);
    assert.deepEqual(haSafetySignalsForDevice(card("d-plug")), ["longRunningPlug", "highPower"]);
    assert.deepEqual(haSafetySignalsForDevice(card("d-climate")), ["longRunningClimate"]);
    // A valve has no signal of its own in the shared vocabulary: its own state never raises an alert,
    // so a closed valve card is pruned whole rather than read for nothing.
    assert.deepEqual(haSafetySignalsForDevice(card("d-valve")), []);
    assert.deepEqual(haSafetySignalsForDevice(card("d-cover")), []);
    // A non-sensor card can still carry an alarm as a 更多设置 facet: `extractSensorObservations`
    // reads those rows for every card kind, so the card keeps its signal while the alert is on.
    assert.deepEqual(haSafetySignalsForDevice(card("d-gas")), []);
    assert.deepEqual(
      haAuxiliarySafetySignals(
        [snapshot.entities.find((e) => e.entity_id === "binary_sensor.gas_leak")!],
        new Map([["binary_sensor.gas_leak", { entityId: "binary_sensor.gas_leak", state: "off", attributes: { device_class: "gas" } }]]),
      ),
      ["gas"],
    );
    assert.deepEqual(splitWith([], ["gas"]).safetyDevices.map((d) => d.id), ["d-gas"]);
    assert.deepEqual(splitWith([], []).safetyDevices, []);
    // The retained card keeps its facets, which is where the evaluator finds the alarm row.
    const gasRetained = splitWith([], ["gas"]);
    assert.ok(Object.hasOwn(gasRetained.safetyDeviceFacets ?? {}, "d-gas"));
    assert.deepEqual(splitWith([], ["starredOffline"], { starredDeviceIds: ["d-light"] }).safetyDevices.map((d) => d.id), ["d-light"]);
    assert.deepEqual(splitWith([], []).safetyDevices, []);
  });

  it("only prunes for an enabled connection and a partial selection", () => {
    assert.equal(haTypePruningActive(selection(DEVICE_CATEGORY_IDS), SCOPE), false);
    assert.equal(haTypePruningActive(selection(["light"]), SCOPE), true);
    assert.equal(haTypePruningActive(selection(["light"], ["ha:https://other.test"]), SCOPE), false);
    assert.equal(haTypePruningActive({ ...selection(["light"]), enabledConnections: ["xiaomi-cloud"] }, SCOPE), false);
  });

  it("leaves platform scenes and scripts startable while a type is closed", () => {
    const pruned = splitWith(["light"]);
    assert.deepEqual(pruned.home.scenes.map((scene) => scene.id), ["scene.movie", "script.leaving"]);
    const scenes = pruned.home.scenes.map((scene) => ({
      id: scene.id, name: scene.name, connection: "home-assistant" as const,
      sourceScope: SCOPE, isSourceAvailable: true,
    }));
    const verdict = evaluateControlTargetGate({
      targetKind: "scene", targetId: "scene.movie", selection: selection(["light"]), devices: [], scenes,
    });
    assert.equal(verdict.allowed, true);
    // The host still warns that a manual scene may control hidden devices (architecture.md §B).
    assert.equal(verdict.mayControlHiddenDevices, true);
  });

  it("names a closed type instead of a missing device for every write entry", () => {
    const storage = memoryStorage();
    const base = resolveMiAccountSelectionState({
      storage, accounts: [], haBaseURL: HA_URL, haToken: HA_TOKEN,
      connectionMode: "homeAssistant", hasExistingPreferences: true,
    });
    // The HA connection is enabled by the fixture; only the device types are closed.
    assert.equal(base.selection.enabledConnectionScopes.includes(SCOPE), true);
    const lightOnly = { ...base.selection, enabledCategories: ["light"] as DeviceCategoryID[] };
    const pruned = splitWith(["light"]);
    const hidden = pruned.hiddenIndexedDevices;
    const context = {
      state: { ...base, selection: lightOnly },
      // The panel only ever holds the drawn cards; the closed ones live in the hidden index.
      accounts: [], devices: [...pruned.home.devices], scenes: [],
      connectionMode: "homeAssistant" as const, dualSourceEnabled: false,
      hiddenDevices: hidden,
    };

    // Card id, multi-track id and entity id, plus an entity that is not the card's primary one.
    for (const target of ["d-cover", "d-cover#cover.living", "cover.living", "d-leak"]) {
      assert.match(
        evaluateDeviceEntityWriteGate({
          targetKind: "device", targetIdOrEntityId: target, resolvedActiveDeviceId: null, context, rejectUnknown: true,
        }) ?? "",
        /该设备类型已关闭/,
        target,
      );
      assert.match(
        evaluateIntentsWriteGate({ intents: [{ targetId: target, operation: { kind: "power", isOn: false } }], context }) ?? "",
        /该设备类型已关闭/,
        target,
      );
    }

    // The index keeps the card resolvable, so the gate answers "closed" rather than "not found".
    assert.match(
      evaluateDeviceEntityWriteGate({
        targetKind: "device", targetIdOrEntityId: "d-cover", resolvedActiveDeviceId: null,
        context: { ...context, hiddenDevices: undefined }, rejectUnknown: true,
      }) ?? "",
      /未找到|不存在/,
    );

    const { indexedDevices } = buildIndexedCapabilityDevices(context);
    const verdict = evaluateControlTargetGate({
      targetKind: "device", targetId: "d-cover", selection: lightOnly, devices: indexedDevices,
    });
    assert.equal(verdict.allowed, false);
    assert.equal(verdict.writeCount, 0);
    assert.equal(verdict.rejectionReason?.code, "categoryDisabled");
    assert.equal(verdict.rejectionReason?.disabledCategory, "cover");

    // A timer or quick action over a hidden target must not run half a plan.
    const planned = evaluatePlanTargetsGate({
      targets: [{ kind: "device", id: "d-light" }, { kind: "device", id: "d-cover" }],
      selection: lightOnly, devices: indexedDevices,
    });
    assert.equal(planned.allowed, false);
    assert.equal(planned.writeCount, 0);
    assert.equal(planned.rejectedTargetId, "d-cover");
    assert.equal(planned.rejectionReason?.code, "categoryDisabled");

    // The URL / companion gate only gets settings, so the host hands it the same index.
    const urlSettings = { connectionMode: "homeAssistant", haBaseURL: HA_URL, haToken: HA_TOKEN, hiddenDevices: hidden };
    assert.match(evaluateDisabledDeviceUrlGate("d-cover", urlSettings, storage) ?? "", /该设备类型已关闭/);
    assert.equal(
      evaluateDisabledDeviceUrlGate("d-cover", { ...urlSettings, hiddenDevices: undefined }, storage),
      null,
    );
    // The drawn card still resolves and writes normally.
    assert.equal(
      evaluateDeviceEntityWriteGate({
        targetKind: "device", targetIdOrEntityId: "d-light", resolvedActiveDeviceId: "d-light", context,
      }),
      null,
    );
    // ...and the wording follows the active language.
    assert.equal(
      evaluateDisabledDeviceUrlGate("d-cover", { ...urlSettings, interfaceLanguage: "en" }, storage),
      "This device category is turned off",
    );
    assert.equal(
      evaluateDisabledDeviceUrlGate("d-cover", { ...urlSettings, interfaceLanguage: "zh-Hant" }, storage),
      "該裝置類型已關閉",
    );
  });

  it("keeps the off-panel snapshot bound to the endpoint that produced it", () => {
    const host = {
      settings: { haBaseURL: HA_URL, haToken: HA_TOKEN, connectionMode: "homeAssistant", dualSourceEnabled: false },
      haTypePruneScope: null as string | null,
      safetyRetainedHADevices: [] as SmartDevice[],
      safetyRetainedHADeviceFacets: {} as Record<string, never>,
      hiddenHADevices: [] as readonly CapabilityIndexedDevice[],
      hiddenMiDevices: [] as readonly CapabilityIndexedDevice[],
    };
    const pruned = splitWith(["light"], ["leak"]);
    assert.ok(pruned.prunePlan);
    applyHaTypePruneSnapshot(host, {
      scope: SCOPE, safetyDevices: pruned.safetyDevices, hiddenDevices: pruned.hiddenIndexedDevices,
    });
    assert.equal(haTypePruneSnapshotIsCurrent(host), true);
    assert.deepEqual(safetyRetainedHADevices(host).map((device) => device.id), ["d-leak"]);
    assert.ok(hiddenTypeDevices(host).some((device) => device.id === "d-cover"));

    // Another endpoint, or another source, makes the whole slice stale: nobody may keep alerting
    // from, or answer for, a connection the app has left.
    for (const stale of [
      { ...host, settings: { ...host.settings, haBaseURL: "https://other.example.test:8123" } },
      { ...host, settings: { ...host.settings, connectionMode: "xiaomiCloud" } },
    ]) {
      assert.equal(haTypePruneSnapshotIsCurrent(stale), false);
      assert.deepEqual(safetyRetainedHADevices(stale), []);
      assert.deepEqual(safetyRetainedHADeviceFacets(stale), {});
      assert.deepEqual(hiddenTypeDevices(stale), []);
    }

    applyHaTypePruneSnapshot(host, null);
    assert.deepEqual(host.hiddenHADevices, []);
    assert.equal(haTypePruneSnapshotIsCurrent(host), false);
  });
});

// The plan is also exercised directly, so a card built outside the synthesizer stays classified by
// the shared partition rather than by a second implementation.
describe("Home Assistant type-prune plan (P3b-W)", () => {
  it("splits cards by the shared verdict", () => {
    const plan = buildHaTypePrunePlan({
      devices: cards,
      selection: selection(["light", "climate"]),
      connectionScope: SCOPE,
      safetySignals: ["leak", "lock"],
    });
    assert.deepEqual([...plan.visibleDeviceIds].sort(), ["d-climate", "d-light"]);
    assert.deepEqual([...plan.safetyRetainedDeviceIds].sort(), ["d-leak", "d-lock"]);
    assert.equal(plan.categoryByDeviceId.get("d-valve"), "valve");
    assert.equal(plan.partition.showsHiddenSafetyNotice, true);
    // Every card that is not drawn keeps an index entry, retained or dropped.
    assert.deepEqual([...plan.hiddenDeviceIds].sort(), [
      "d-contact", "d-cover", "d-gas", "d-leak", "d-lock", "d-plug", "d-smoke", "d-valve",
    ]);
    assert.equal(plan.hiddenIndexedDevices.length, plan.hiddenDeviceIds.size);
  });
});
