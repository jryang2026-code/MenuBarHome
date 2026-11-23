import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import {
  evaluateControlTargetGate, evaluatePlanTargetsGate,
  type CapabilitySelection, type SafetySignalKind,
} from "../src/core/capabilityReferenceVerdict.js";
import { DEVICE_CATEGORY_IDS, type DeviceCategoryID } from "../src/core/capabilityManifest.js";
import { parseMiotDeviceSpec, type MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { propKeyString, type MiDeviceRecord, type MiotPropKey } from "../src/core/miCloud/client.js";
import {
  buildMiotTypePrunePlan, miotSafetySignalsForPrefs, miotSafetySignalsForSensorPolicy, type MiotSafetyPrefs,
} from "../src/core/miotTypePruning.js";
import {
  createDefaultSensorAlertPolicy, evaluateSensorAlerts, inferSensorAlertKindsFromMetadata,
} from "../src/core/safetyAndHealth.js";
import { currentLanguage, setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { makeMiAccount, mergeMiAccountSnapshots, refreshMiAccountsConcurrently, type AccountChildSnapshot } from "../src/core/miAccountsStore.js";
import {
  buildIndexedCapabilityDevices, evaluateDeviceEntityWriteGate, evaluateDisabledDeviceUrlGate, previewDeviceCategorySelection,
  evaluateDisabledUtteranceGate, evaluateIntentsWriteGate, resolveMiAccountSelectionState,
} from "../src/core/miAccountControl.js";
import { AutomationRuleStore } from "../src/core/automationEngine.js";
import { ScheduledCommandStore } from "../src/core/scheduledCommands.js";
import { applyMiotTypePruneSnapshot, buildHostCapabilityContext } from "../src/ui/cloudRefresh.js";
import { MiotSpecResolver } from "../src/core/miCloud/spec.js";
import type { MiRoom, MiSession } from "../src/core/miCloudClient.js";

// Real specs from the shared MIoT corpus, so the plan runs against the fixtures both platforms
// parse: a curtain, a light, an outlet, water-leak, smoke, gas, door-contact and lock sensors, and a
// generic fish tank whose alarm text exists only as facet labels.
const rawSpecs = JSON.parse(
  readFileSync(resolve(process.cwd(), "../Tests/Fixtures/miot_coverage_specs.json"), "utf8"),
) as Record<string, unknown>;

const MODEL_BY_DID = {
  curtain: "090615.curtain.1mcu01",
  light: "miot.light.hyz05",
  plug: "090615.plug.cmp86",
  leak: "bkxh.flood.yf02",
  smoke: "bkxh.sensor_smoke.s1",
  gas: "bkxh.sensor_gas.s2",
  contact: "bkxh.magnet.yf01",
  lock: "bdf668.lock.mf24n",
  tank: "209754.fishbowl.tank01",
} as const;
type TestDid = keyof typeof MODEL_BY_DID;
const DIDS = Object.keys(MODEL_BY_DID) as TestDid[];

const specs: Record<string, MiotDeviceSpec> = {};
for (const model of Object.values(MODEL_BY_DID)) {
  const spec = parseMiotDeviceSpec(rawSpecs[model]);
  assert.ok(spec, `shared fixture spec parses: ${model}`);
  specs[model] = spec;
}

const SCOPE = "mi:acc1";
const NAMES: Record<TestDid, string> = {
  curtain: "客厅窗帘", light: "客厅灯", plug: "电热水壶", leak: "厨房水浸", smoke: "烟雾",
  gas: "燃气", contact: "阳台门窗", lock: "门锁", tank: "鱼缸",
};

const devices: MiDeviceRecord[] = DIDS.map((did) => ({
  did, name: NAMES[did], model: MODEL_BY_DID[did], isOnline: true, specType: null,
}));
const record = (did: TestDid): MiDeviceRecord => devices[DIDS.indexOf(did)]!;
const spec = (did: TestDid): MiotDeviceSpec => specs[MODEL_BY_DID[did]]!;

const ALL_SENSOR_SIGNALS: readonly SafetySignalKind[] = ["leak", "smoke", "gas", "contact", "motion", "vibration", "lock"];

function selection(categories: readonly DeviceCategoryID[], scopes: readonly string[] = [SCOPE]): CapabilitySelection {
  return {
    enabledConnections: ["xiaomi-cloud"],
    enabledConnectionScopes: [...scopes],
    enabledFeatures: [],
    enabledCategories: [...categories],
  };
}

function planWith(categories: readonly DeviceCategoryID[], safetySignals: readonly SafetySignalKind[] = ALL_SENSOR_SIGNALS) {
  return buildMiotTypePrunePlan({
    rawDevices: devices,
    specs,
    selection: selection(categories),
    connectionScope: SCOPE,
    safetySignals,
  });
}

const readIds = (keys: readonly MiotPropKey[]): string[] => keys.map(propKeyString);
const readsOf = (keys: readonly MiotPropKey[], did: string): string[] =>
  readIds(keys.filter((key) => key.did === did)).sort();

describe("Mi device-type pruning (P3a-W)", () => {
  it("classifies cards from the shared MIoT specs, including dual-track covers", () => {
    const plan = planWith(DEVICE_CATEGORY_IDS);
    assert.equal(plan.categoryByDeviceId.get("curtain"), "cover");
    assert.equal(plan.categoryByDeviceId.get("light"), "light");
    assert.equal(plan.categoryByDeviceId.get("plug"), "plug");
    for (const did of ["leak", "contact", "lock"] as const) {
      assert.equal(plan.categoryByDeviceId.get(did), "sensor", did);
    }
    // Smoke and gas sensors have no dedicated builder, so they are generic facet cards.
    for (const did of ["smoke", "gas", "tank"] as const) {
      assert.equal(plan.categoryByDeviceId.get(did), "generic", did);
    }
    // A dual-track curtain motor publishes one card per track; every track stays a cover.
    const curtainCards = [...plan.categoryByDeviceId.keys()].filter((id) => id.startsWith("curtain"));
    assert.ok(curtainCards.length >= 1, curtainCards.join(","));
    for (const id of curtainCards) assert.equal(plan.categoryByDeviceId.get(id), "cover", id);
  });

  it("keeps today's read set when every type is enabled", () => {
    const plan = planWith(DEVICE_CATEGORY_IDS);
    const legacy = DIDS.flatMap((did) => [
      ...MiotSynthesizer.requiredProps(record(did), spec(did)),
      ...MiotSynthesizer.facetProps(record(did), spec(did)),
    ]);
    assert.deepEqual(readIds(plan.readKeys).sort(), [...new Set(readIds(legacy))].sort());
    assert.deepEqual([...plan.skippedDeviceIds], []);
    assert.equal(plan.safetyRecords.length, 0);
    assert.equal(plan.safetyRetainedDeviceIds.size, 0);
  });

  it("drops a closed cover and keeps the alert reads of a closed sensor type", () => {
    const plan = planWith(["light", "plug"]);
    // A closed curtain carries no safety signal, so it costs no reads at all.
    assert.equal(plan.visibleDeviceIds.has("curtain"), false);
    assert.ok([...plan.skippedDeviceIds].some((id) => id.startsWith("curtain")));
    assert.equal(plan.visibleRecords.some((r) => r.did === "curtain"), false);
    assert.equal(plan.safetyRecords.some((r) => r.did === "curtain"), false);
    assert.deepEqual(readsOf(plan.readKeys, "curtain"), []);
    // Kept cards read exactly what they read today, drawer rows included.
    assert.ok(plan.visibleDeviceIds.has("light"));
    assert.deepEqual(
      readsOf(plan.readKeys, "light"),
      [...new Set([
        ...readIds(MiotSynthesizer.requiredProps(record("light"), spec("light"))),
        ...readIds(MiotSynthesizer.facetProps(record("light"), spec("light"))),
      ])].sort(),
    );
    // A retained sensor keeps every read its alert can come from - card properties or facets -
    // but it is no longer a card.
    for (const did of ["leak", "contact", "lock"] as const) {
      assert.equal(plan.visibleDeviceIds.has(did), false, did);
      assert.ok(plan.safetyRetainedDeviceIds.has(did), did);
      assert.deepEqual(
        readsOf(plan.readKeys, did),
        [...new Set([
          ...readIds(MiotSynthesizer.requiredProps(record(did), spec(did))),
          ...readIds(MiotSynthesizer.facetProps(record(did), spec(did))),
        ])].sort(),
        did,
      );
    }
  });

  it("derives each device's own signals, so an unrelated hidden device stops reading", () => {
    // Only a smoke alert is on: a water-leak sensor has nothing to contribute and is pruned whole,
    // and the generic fish tank names no safety signal at all.
    const smokeOnly = planWith(["light"], ["smoke"]);
    assert.equal(smokeOnly.safetyRetainedDeviceIds.has("leak"), false);
    assert.equal(smokeOnly.readKeys.some((key) => key.did === "leak"), false);
    assert.equal(smokeOnly.readKeys.some((key) => key.did === "tank"), false);
    assert.ok(smokeOnly.safetyRetainedDeviceIds.has("smoke"));
    // A contact sensor reports contact, not smoke.
    assert.equal(smokeOnly.safetyRetainedDeviceIds.has("contact"), false);
    // And with the leak alert on, the same sensor is back.
    assert.ok(planWith(["light"], ["leak"]).safetyRetainedDeviceIds.has("leak"));
  });

  it("keeps a facet-only card's alert reads, because that is where its labels live", () => {
    const plan = planWith(["light"]);
    // Smoke and gas sensors have no dedicated builder: their alarm text is a facet value list.
    for (const did of ["smoke", "gas"] as const) {
      assert.ok(plan.safetyRetainedDeviceIds.has(did), did);
      assert.ok(readsOf(plan.readKeys, did).length > 0, did);
      assert.equal(MiotSynthesizer.requiredProps(record(did), spec(did)).length, 0, `${did}: no card properties`);
    }
  });

  it("stops the exclusive reads once the matching alert is switched off", () => {
    const withAlerts = planWith(["light"], ALL_SENSOR_SIGNALS);
    const noAlerts = planWith(["light"], []);
    assert.ok(readsOf(withAlerts.readKeys, "leak").length > 0);
    assert.equal(noAlerts.safetyRetainedDeviceIds.size, 0);
    assert.equal(noAlerts.safetyRecords.length, 0);
    // Nothing but the kept type is read once no alert needs a hidden signal.
    assert.deepEqual(
      readIds(noAlerts.readKeys).sort(),
      [...new Set(readIds(noAlerts.readKeys.filter((key) => key.did === "light")))].sort(),
    );
  });

  it("still fires a water-leak alert from a retained sensor", () => {
    const plan = planWith(["light", "plug"]);
    assert.ok(plan.safetyRetainedDeviceIds.has("leak"));
    const values = new Map<string, unknown>([["leak.2.1006", true]]);
    const safetyHome = MiotSynthesizer.synthesize(plan.safetyRecords, [], specs, values);
    const leakCard = safetyHome.devices.find((device) => device.id === "leak");
    assert.ok(leakCard, "retained device synthesizes for evaluation");
    assert.equal(leakCard.kind.kind, "sensor");
    // A retained device never joins the card list, so its shape is evaluation-only.
    assert.equal(plan.visibleRecords.some((r) => r.did === "leak"), false);

    const policy = createDefaultSensorAlertPolicy(false);
    const evaluation = evaluateSensorAlerts([leakCard] as SmartDevice[], {}, 1_700_000_000_000, policy);
    assert.equal(evaluation.alerts.length, 1);
    assert.equal(evaluation.alerts[0]!.sensorKind, "leak");
    assert.equal(evaluation.alerts[0]!.category, "sensor");
    assert.equal(evaluation.alerts[0]!.priority, "high");
    // A hidden device offers no direct control action, only its signal.
    assert.equal(evaluation.alerts[0]!.turnOffCommand, undefined);
    const cleared = evaluateSensorAlerts([leakCard] as SmartDevice[], evaluation.ledger, 1_700_000_030_000, policy);
    assert.equal(cleared.alerts.length, 0);
  });

  it("shares one plan across accounts, and stays unpruned while a scope is still unknown", () => {
    const known = buildMiotTypePrunePlan({
      rawDevices: devices,
      specs,
      selection: selection(["light", "plug"], ["mi:acc1", "mi:acc2"]),
      connectionScope: "mi:acc2",
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    assert.equal(known.visibleDeviceIds.has("light"), true);
    assert.equal(known.visibleDeviceIds.has("curtain"), false);
    assert.deepEqual(readsOf(known.readKeys, "curtain"), []);

    // A scope the selection does not know yet (mid-migration) keeps every read, so a device never
    // disappears because its account was still being adopted.
    const unknown = buildMiotTypePrunePlan({
      rawDevices: devices,
      specs,
      selection: selection(["light", "plug"], ["mi:acc2"]),
      connectionScope: "mi:acc1",
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    assert.equal(unknown.visibleDeviceIds.has("curtain"), true);
    assert.ok(readsOf(unknown.readKeys, "curtain").length > 0);
  });

  it("infers a device's own alert kinds from the same metadata the evaluator reads", () => {
    // The single-kind form evaluation uses stays the first match of the multi-kind form.
    assert.deepEqual(inferSensorAlertKindsFromMetadata("bkxh.flood.yf02 submersion-state"), ["leak"]);
    assert.deepEqual(inferSensorAlertKindsFromMetadata("bkxh.sensor_smoke.s1 smoke-sensor"), ["smoke"]);
    assert.deepEqual(inferSensorAlertKindsFromMetadata("bkxh.sensor_gas.s2 gas-sensor"), ["gas"]);
    assert.deepEqual(inferSensorAlertKindsFromMetadata("bkxh.magnet.yf01 magnet-sensor contact-state"), ["contact"]);
    assert.deepEqual(inferSensorAlertKindsFromMetadata("bdf668.lock.mf24n door-state"), ["lock", "contact"]);
    assert.deepEqual(inferSensorAlertKindsFromMetadata("209754.fishbowl.tank01 fish-tank"), []);
  });

  it("maps sensor-alert settings to the shared safety-signal vocabulary", () => {
    const defaults = miotSafetySignalsForSensorPolicy(createDefaultSensorAlertPolicy(false));
    assert.deepEqual([...defaults].sort(), ["gas", "leak", "lock", "smoke"]);
    const custom = miotSafetySignalsForSensorPolicy({ enabled: { leak: false, contact: true }, onlyWhenAway: true, includesAway: false });
    assert.ok(custom.includes("contact"));
    assert.equal(custom.includes("leak"), false);
  });

  it("skips the light-group membership query while the light type is off", async () => {
    const rooms: MiRoom[] = [{
      id: "room1", name: "客厅", homeId: "home1", homeName: "我的家",
      dids: devices.map((device) => device.did), isSharedHome: false,
    }];
    // A group did is what makes the refresh ask for membership at all.
    const groupRecord: MiDeviceRecord = {
      did: "group.living", name: "客厅灯组", model: MODEL_BY_DID.light, isOnline: true, specType: null,
    };
    const withGroup = [...devices, groupRecord];
    const roomFor = (dids: readonly string[]): MiRoom[] => [{ ...rooms[0]!, dids: [...dids] }];
    const session: MiSession = {
      userId: "acc1", cUserId: "", ssecurity: "sec", serviceToken: "tok", passToken: "", region: "cn",
    };
    const account = makeMiAccount(session);
    const transport = async () => ({ status: 200, headers: {}, body: "{}" });

    const runWith = async (enabledCategories: readonly DeviceCategoryID[]) => {
      const membershipCalls: string[][] = [];
      const client = {
        deviceList: async () => withGroup,
        homeRooms: async () => roomFor(withGroup.map((device) => device.did)),
        devicesByDids: async () => [],
        homeDevices: async () => [],
        lightGroupMembers: async (dids: readonly string[]) => {
          membershipCalls.push([...dids]);
          return new Map<string, string[]>([["group.living", ["light"]]]);
        },
        getProps: async () => new Map<string, unknown>(),
      };
      const result = await refreshMiAccountsConcurrently({
        accounts: [account],
        transport,
        specResolver: new MiotSpecResolver(transport, specs),
        prune: { selection: selection(enabledCategories, [account.id]), safetySignals: [...ALL_SENSOR_SIGNALS] },
        clientFactory: () => client as never,
      });
      return { membershipCalls, child: result.children[account.id] as AccountChildSnapshot };
    };

    // `light` on: the group card is drawn, so its membership is worth a request.
    const lightsOn = await runWith(["light", "plug"]);
    assert.deepEqual(lightsOn.membershipCalls, [["group.living"]]);
    assert.equal(lightsOn.child.lightGroupOwners.get("light"), "group.living");

    // `light` off: no group card is drawn, so the per-group request is skipped and nothing is folded.
    const lightsOff = await runWith(["plug"]);
    assert.deepEqual(lightsOff.membershipCalls, []);
    assert.equal(lightsOff.child.lightGroupOwners.size, 0);

    // A selection that prunes nothing (every type on) still asks: the scope is unknown or full.
    const everyType = await runWith([...DEVICE_CATEGORY_IDS]);
    assert.deepEqual(everyType.membershipCalls, [["group.living"]]);
  });

  it("prunes the per-account refresh and keeps the alert-only half on the child snapshot", async () => {
    const rooms: MiRoom[] = [{
      id: "room1", name: "客厅", homeId: "home1", homeName: "我的家",
      dids: devices.map((device) => device.did), isSharedHome: false,
    }];
    const readKeys: string[] = [];
    const client = {
      deviceList: async () => devices,
      homeRooms: async () => rooms,
      devicesByDids: async () => [],
      homeDevices: async () => [],
      lightGroupMembers: async () => new Map<string, string[]>(),
      getProps: async (keys: readonly MiotPropKey[]) => {
        readKeys.push(...keys.map(propKeyString));
        return new Map<string, unknown>([["leak.2.1006", true]]);
      },
    };
    const session: MiSession = {
      userId: "acc1", cUserId: "", ssecurity: "sec", serviceToken: "tok", passToken: "", region: "cn",
    };
    const account = makeMiAccount(session);
    const transport = async () => ({ status: 200, headers: {}, body: "{}" });
    const refresh = (categories: readonly DeviceCategoryID[]) => refreshMiAccountsConcurrently({
      accounts: [account],
      transport,
      specResolver: new MiotSpecResolver(transport, specs),
      prune: { selection: selection(categories, [account.id]), safetySignals: [...ALL_SENSOR_SIGNALS] },
      clientFactory: () => client as never,
    });
    const { merged: allTypes } = await refresh(DEVICE_CATEGORY_IDS);
    const host = {
      settings: { connectionMode: "xiaomiCloud", miSession: session },
      devices: allTypes.home.devices,
      miTypeSafetySignals: {},
    };
    applyMiotTypePruneSnapshot(host, allTypes);
    const storage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
    const preview = previewDeviceCategorySelection({
      context: buildHostCapabilityContext(host, [account]), proposedCategories: ["light"],
      scheduledCommandStore: new ScheduledCommandStore(storage), activeTimerIdentity: null,
      ruleStore: new AutomationRuleStore(storage), safetyPolicy: { enabledSignals: ALL_SENSOR_SIGNALS },
    });
    readKeys.length = 0;
    const { merged, children } = await refresh(["light"]);

    // Only the kept type is a card; the curtain is neither a card nor a read.
    assert.deepEqual(merged.home.devices.map((device) => device.id), ["light"]);
    assert.equal(readKeys.some((id) => id.startsWith("curtain.")), false);
    // The leak sensor keeps the one read its alert needs and rides along for evaluation only.
    assert.ok(readKeys.includes("leak.2.1006"));
    const child = children[account.id] as AccountChildSnapshot;
    // The fish tank only ever looked like a lock because it publishes `physical-controls-locked`,
    // so it is no longer retained for anything.
    assert.deepEqual((child.safetyDevices ?? []).map((device) => device.id).sort(), ["contact", "gas", "leak", "lock", "smoke"]);
    assert.equal(child.home.devices.some((device) => device.id === "leak"), false);
    assert.deepEqual(merged.safetyDevices?.map((device) => device.id).sort(), ["contact", "gas", "leak", "lock", "smoke"]);
    assert.deepEqual(preview.retainedSafetyCards.map((device) => device.id).sort(), merged.safetyDevices?.map((device) => device.id).sort());
    assert.ok(preview.retainedSafetySignals.includes("leak"));

    // A disconnected account's stale alert devices never reach the merged evaluation set.
    const offline = mergeMiAccountSnapshots([account], {
      [account.id]: { ...child, status: { kind: "disconnected", reason: "offline" } },
    });
    assert.deepEqual(offline.safetyDevices ?? [], []);
  });

  it("still names a closed type from the index after the account's refresh fails", async () => {
    const rooms: MiRoom[] = [{
      id: "room1", name: "客厅", homeId: "home1", homeName: "我的家",
      dids: devices.map((device) => device.did), isSharedHome: false,
    }];
    const session: MiSession = {
      userId: "acc1", cUserId: "", ssecurity: "sec", serviceToken: "tok", passToken: "", region: "cn",
    };
    const account = makeMiAccount(session);
    const transport = async () => ({ status: 200, headers: {}, body: "{}" });
    const selectionFor = selection(["light"], [account.id]);
    const clientFor = (fail: boolean) => ({
      deviceList: async () => {
        if (fail) throw new Error("network down");
        return devices;
      },
      homeRooms: async () => rooms,
      devicesByDids: async () => [],
      homeDevices: async () => [],
      lightGroupMembers: async () => new Map<string, string[]>(),
      getProps: async () => new Map<string, unknown>(),
    });
    const run = (fail: boolean, previousSnapshots?: Record<string, AccountChildSnapshot>) =>
      refreshMiAccountsConcurrently({
        accounts: [account],
        transport,
        specResolver: new MiotSpecResolver(transport, specs),
        prune: { selection: selectionFor, safetySignals: [...ALL_SENSOR_SIGNALS] },
        clientFactory: () => clientFor(fail) as never,
        ...(previousSnapshots ? { previousSnapshots } : {}),
      });

    const first = await run(false);
    const closedIds = (first.children[account.id] as AccountChildSnapshot).hiddenDevices ?? [];
    assert.ok(closedIds.some((device) => device.id === "curtain"), "the closed cover is indexed");

    // A failed round keeps the last snapshot on screen, so the same closed type must stay nameable
    // instead of falling back to "no such device" (Nit-12).
    const failed = await run(true, first.children);
    const child = failed.children[account.id] as AccountChildSnapshot;
    assert.equal(child.status.kind, "disconnected");
    assert.deepEqual(
      (child.hiddenDevices ?? []).map((device) => device.id).sort(),
      closedIds.map((device) => device.id).sort(),
    );
    // ...but the stale entry cannot authorize a write while the account is not answering.
    const curtain = (failed.merged.hiddenDevices ?? []).find((device) => device.id === "curtain");
    assert.ok(curtain, "the merged index still names the closed cover");
    assert.equal(curtain.isSourceAvailable, false);
  });

  it("keeps a closed card in the identity index so the gate names it, with zero writes", () => {
    const storageMap = new Map<string, string>();
    const storage = {
      getItem: (key: string): string | null => storageMap.get(key) ?? null,
      setItem: (key: string, value: string): void => { storageMap.set(key, value); },
      removeItem: (key: string): void => { storageMap.delete(key); },
    };
    const session: MiSession = {
      userId: "acc1", cUserId: "", ssecurity: "sec", serviceToken: "tok", passToken: "", region: "cn",
    };
    const account = makeMiAccount(session);
    const base = resolveMiAccountSelectionState({ storage, accounts: [account], hasExistingPreferences: true });
    const selectionWith = { ...base.selection, enabledCategories: ["light"] as DeviceCategoryID[] };
    const state = { ...base, selection: selectionWith };
    const plan = buildMiotTypePrunePlan({
      rawDevices: devices,
      specs,
      selection: selectionWith,
      connectionScope: account.id,
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    const context = {
      state, accounts: [account], devices: [], scenes: [],
      connectionMode: "xiaomiCloud" as const, dualSourceEnabled: false,
      hiddenDevices: plan.hiddenIndexedDevices,
    };
    const { indexedDevices } = buildIndexedCapabilityDevices(context);
    assert.ok(indexedDevices.some((device) => device.id === "curtain"), "curtain stays indexable");
    const verdict = evaluateControlTargetGate({
      targetKind: "device", targetId: "curtain", selection: selectionWith, devices: indexedDevices,
    });
    assert.equal(verdict.allowed, false);
    assert.equal(verdict.writeCount, 0);
    assert.equal(verdict.rejectionReason?.code, "categoryDisabled");
    assert.equal(verdict.rejectionReason?.disabledCategory, "cover");

    // A timer or quick action over a closed target must not run half a plan.
    const planned = evaluatePlanTargetsGate({
      targets: [{ kind: "device", id: "curtain" }, { kind: "device", id: "tank" }],
      selection: selectionWith,
      devices: indexedDevices,
    });
    assert.equal(planned.allowed, false);
    assert.equal(planned.writeCount, 0);
    assert.equal(planned.rejectedTargetId, "curtain");
    assert.equal(planned.rejectionReason?.code, "categoryDisabled");

    // ...and without the hidden index the same target would read as never having existed.
    const withoutIndex = buildIndexedCapabilityDevices({ ...context, hiddenDevices: undefined });
    assert.equal(
      evaluateControlTargetGate({ targetKind: "device", targetId: "curtain", selection: selectionWith, devices: withoutIndex.indexedDevices })
        .rejectionReason?.code,
      "deviceNotFound",
    );
  });
});

// --- Cross-model review fixes: real corpus, real locks, host switches and the write gate -----------

/** Every spec in the shared corpus, one record each, so the plan runs on all 208 real topologies. */
const corpus: { readonly records: readonly MiDeviceRecord[]; readonly specs: Record<string, MiotDeviceSpec> } = (() => {
  const models = Object.keys(rawSpecs).sort();
  const parsed: Record<string, MiotDeviceSpec> = {};
  const list: MiDeviceRecord[] = [];
  models.forEach((model, index) => {
    const spec = parseMiotDeviceSpec(rawSpecs[model]);
    assert.ok(spec, `shared fixture spec parses: ${model}`);
    parsed[model] = spec;
    list.push({ did: `c${index}`, name: model.split(".").slice(-1)[0]!, model, isOnline: true, specType: null });
  });
  return { records: list, specs: parsed };
})();

function corpusPlan(categories: readonly DeviceCategoryID[], safetySignals: readonly SafetySignalKind[]) {
  return buildMiotTypePrunePlan({
    rawDevices: corpus.records,
    specs: corpus.specs,
    selection: selection(categories, ["mi:corpus"]),
    connectionScope: "mi:corpus",
    safetySignals,
  });
}

/** The plan id is the raw did, or `<did>.s<siid>` for a split curtain track. */
const recordIndexFor = (planId: string): number =>
  Number(planId.startsWith("c") && planId.includes(".") ? planId.slice(1, planId.indexOf(".")) : planId.slice(1));
const modelForPlanId = (planId: string): string => corpus.records[recordIndexFor(planId)]!.model;
/** Every read key planned for one corpus model, including its split-track plan ids. */
const readsForModel = (plan: ReturnType<typeof corpusPlan>, model: string): string[] => {
  const index = corpus.records.findIndex((device) => device.model === model);
  return readIds(plan.readKeys.filter((key) => key.did === `c${index}` || key.did.startsWith(`c${index}.`)));
};

describe("Mi device-type pruning review fixes (P3a-W)", () => {
  it("keeps every record and read key when all types are on, across all 208 corpus specs", () => {
    const plan = corpusPlan(DEVICE_CATEGORY_IDS, ALL_SENSOR_SIGNALS);
    const legacy = corpus.records.flatMap((dev) => [
      ...MiotSynthesizer.requiredProps(dev, corpus.specs[dev.model]!),
      ...MiotSynthesizer.facetProps(dev, corpus.specs[dev.model]!),
    ]);
    assert.deepEqual(readIds(plan.readKeys).sort(), [...new Set(readIds(legacy))].sort());
    assert.deepEqual([...plan.skippedDeviceIds], []);
    assert.deepEqual([...plan.hiddenIndexedDevices], []);
    assert.equal(plan.safetyRetainedDeviceIds.size, 0);
    assert.equal(plan.visibleRecords.length, corpus.records.length);
  });

  it("keeps a real lock's lock signal even though it publishes child-lock", () => {
    // `miot.lock.ble22` has `child-lock`; joining every field into one string used to drop the signal.
    const plan = corpusPlan(["light"], ["lock"]);
    const retainedModels = new Set([...plan.safetyRetainedDeviceIds].map(modelForPlanId));
    assert.ok(retainedModels.has("miot.lock.ble22"));
    assert.ok(readsForModel(plan, "miot.lock.ble22").length > 0);
    const lockIndex = corpus.records.findIndex((device) => device.model === "miot.lock.ble22");
    assert.deepEqual(
      plan.hiddenIndexedDevices.find((device) => device.id === `c${lockIndex}`)?.safetySignals,
      ["contact", "lock", "lowBattery"],
    );

    // A smart door is neither a sensor nor a generic card, but it still reports lock and motion.
    const doorPlan = corpusPlan(["light"], ["lock", "motion"]);
    const doorIndex = corpus.records.findIndex((device) => device.model === "chuangmi.door.515a01");
    assert.deepEqual(
      doorPlan.hiddenIndexedDevices.find((device) => device.id === `c${doorIndex}`)?.safetySignals,
      ["contact", "motion", "lock"],
    );
    assert.ok(readsForModel(doorPlan, "chuangmi.door.515a01").length > 0);
  });

  it("never takes a lock's own child-lock or physical-controls-locked for the lock signal", () => {
    // Aquariums, shower heads, feeders and kettles publish `physical-controls-locked`; that is a
    // lockout, so none of them may end up in the retained set for the lock alert.
    const plan = corpusPlan(["light"], ["lock"]);
    const retainedModels = new Set([...plan.safetyRetainedDeviceIds].map(modelForPlanId));
    for (const model of [
      "209754.fishbowl.tank01", "xiaomi.fishbowl.m200", "xiaomi.fishbowl.m300", "hfjh.fishbowl.m100",
      "445.shower.lyq01", "445.tow_w.mjj1", "xiaomi.feeder.iv2002", "chunmi.ysj.tsa1", "enchen.razor.bs8",
    ]) {
      assert.equal(retainedModels.has(model), false, model);
    }
    // The real locks in the same corpus are still retained.
    for (const model of ["miot.lock.ble22", "bdf668.lock.mf24n"]) assert.ok(retainedModels.has(model), model);
  });

  it("leaves a record with no spec visible and out of the read plan", () => {
    const known = record("light");
    const unknown: MiDeviceRecord = { did: "nospec", name: "未知设备", model: "acme.unknown.x1", isOnline: true, specType: null };
    const plan = buildMiotTypePrunePlan({
      rawDevices: [known, unknown],
      specs,
      selection: selection(["plug"]),
      connectionScope: SCOPE,
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    // Before P3a-W `collectMiotPropKeys` read nothing for a spec-less record; that stays true.
    assert.equal(plan.visibleDeviceIds.has("nospec"), true);
    assert.equal(plan.skippedDeviceIds.has("nospec"), false);
    assert.equal(plan.visibleRecords.some((device) => device.did === "nospec"), true);
    assert.deepEqual(readsOf(plan.readKeys, "nospec"), []);
    assert.equal(plan.hiddenIndexedDevices.some((device) => device.id === "nospec"), false);
  });

  it("does not plan a split parent, because only its tracks are drawn", () => {
    const parent: MiDeviceRecord = { did: "panel", name: "三键面板", model: MODEL_BY_DID.light, isOnline: true, specType: null };
    const child: MiDeviceRecord = { ...parent, did: "panel.s2", splitParentDid: "panel", splitSiid: 2 };
    const planFor = (records: readonly MiDeviceRecord[]) => buildMiotTypePrunePlan({
      rawDevices: records,
      specs,
      selection: selection(["light"]),
      connectionScope: SCOPE,
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    const withParent = planFor([parent, child]);
    // MIoT property calls address the parent did, so the child's keys carry it; planning the parent
    // as well would add its whole-spec keys on top.
    assert.deepEqual(readIds(withParent.readKeys).sort(), readIds(planFor([child]).readKeys).sort());
    assert.equal(withParent.categoryByDeviceId.has("panel"), false);
    assert.equal(withParent.hiddenIndexedDevices.some((device) => device.id === "panel"), false);
    assert.equal(withParent.visibleDeviceIds.has("panel.s2"), true);
    assert.equal(withParent.visibleRecords.some((device) => device.did === "panel"), false);
  });

  it("keeps the sensor alerts while the master switch above them is off", () => {
    const off: MiotSafetyPrefs = {
      enableSafetyAlerts: false, longRunningPlug: true, longRunningClimate: true, lowBattery: true,
      favoriteOffline: true,
    };
    // 主动安全守护与低电量提醒 only owns its own four rows; the sensor block below it has its own
    // switches, so smoke/gas/leak/lock keep reading while it is off.
    assert.deepEqual(
      miotSafetySignalsForPrefs(off, createDefaultSensorAlertPolicy(false)),
      ["leak", "smoke", "gas", "lock"],
    );
    // ...and the master switch's own rows really are off, even though the user left them ticked.
    for (const kind of ["lowBattery", "longRunningPlug", "longRunningClimate", "highPower", "starredOffline"] as const) {
      assert.equal(miotSafetySignalsForPrefs(off, createDefaultSensorAlertPolicy(false)).includes(kind), false, kind);
    }
    // A sensor alert the user switched off is still off, and an unspecified kind keeps its default.
    assert.deepEqual(
      miotSafetySignalsForPrefs(off, { enabled: { leak: false }, onlyWhenAway: false, includesAway: false }),
      ["smoke", "gas", "lock"],
    );
  });

  it("keeps a hidden smoke, gas, leak or lock sensor while the master switch is off", () => {
    const off: MiotSafetyPrefs = {
      enableSafetyAlerts: false, longRunningPlug: false, longRunningClimate: false, lowBattery: false,
      favoriteOffline: false,
    };
    const defaultPolicy = createDefaultSensorAlertPolicy(false);
    const signals = miotSafetySignalsForPrefs(off, defaultPolicy);
    const plan = planWith(["light"], signals);
    for (const did of ["smoke", "gas", "leak"] as const) {
      assert.ok(plan.safetyRetainedDeviceIds.has(did), did);
      assert.ok(readsOf(plan.readKeys, did).length > 0, did);
    }
    assert.ok(plan.safetyRetainedDeviceIds.has("lock"));
    // The water-leak sensor still raises its alert from the retained record's own state.
    const safetyHome = MiotSynthesizer.synthesize(plan.safetyRecords, [], specs, new Map([["leak.2.1006", true]]));
    const leakCard = safetyHome.devices.find((device) => device.id === "leak");
    assert.ok(leakCard);
    assert.equal(evaluateSensorAlerts([leakCard] as SmartDevice[], {}, 1_700_000_000_000, defaultPolicy).alerts.length, 1);
    // ...and with every sensor switch off too, nothing is retained at all.
    const everySensorOff = { enabled: { leak: false, smoke: false, gas: false, lock: false, contact: false, motion: false, vibration: false }, onlyWhenAway: false, includesAway: false };
    assert.deepEqual(miotSafetySignalsForPrefs(off, everySensorOff), []);
    assert.equal(planWith(["light"], miotSafetySignalsForPrefs(off, everySensorOff)).safetyRetainedDeviceIds.size, 0);
  });

  it("maps the long-run, battery and pinned-offline switches onto their own signals", () => {
    const policy = createDefaultSensorAlertPolicy(false);
    const all = miotSafetySignalsForPrefs(
      {
        enableSafetyAlerts: true, longRunningPlug: true, longRunningClimate: true, lowBattery: true,
        favoriteOffline: true,
      },
      policy,
    );
    for (const kind of ["gas", "leak", "lock", "smoke", "highPower", "longRunningPlug", "longRunningClimate", "lowBattery", "starredOffline"] as const) {
      assert.ok(all.includes(kind), kind);
    }
    const none = miotSafetySignalsForPrefs(
      {
        enableSafetyAlerts: true, longRunningPlug: false, longRunningClimate: false, lowBattery: false,
        favoriteOffline: false,
      },
      policy,
    );
    for (const kind of ["highPower", "longRunningPlug", "longRunningClimate", "lowBattery", "starredOffline"] as const) {
      assert.equal(none.includes(kind), false, kind);
    }
    // Turning the plug switch on is what keeps a closed plug reading its power draw.
    const withoutPlug = planWith(["light"], none);
    assert.equal(withoutPlug.safetyRetainedDeviceIds.has("plug"), false);
    assert.deepEqual(readsOf(withoutPlug.readKeys, "plug"), []);
    const withPlug = planWith(["light"], all);
    assert.ok(withPlug.safetyRetainedDeviceIds.has("plug"));
  });

  it("names a closed type instead of a missing device for entity, voice and URL writes", () => {
    const storageMap = new Map<string, string>();
    const storage = {
      getItem: (key: string): string | null => storageMap.get(key) ?? null,
      setItem: (key: string, value: string): void => { storageMap.set(key, value); },
      removeItem: (key: string): void => { storageMap.delete(key); },
    };
    const session: MiSession = {
      userId: "acc1", cUserId: "", ssecurity: "sec", serviceToken: "tok", passToken: "", region: "cn",
    };
    const account = makeMiAccount(session);
    const base = resolveMiAccountSelectionState({ storage, accounts: [account], hasExistingPreferences: true });
    const plugOnly = { ...base.selection, enabledCategories: ["plug"] as DeviceCategoryID[] };
    const closePlan = buildMiotTypePrunePlan({
      rawDevices: [record("light"), record("curtain")],
      specs,
      selection: plugOnly,
      connectionScope: account.id,
      safetySignals: ALL_SENSOR_SIGNALS,
    });
    const context = {
      state: { ...base, selection: plugOnly },
      accounts: [account], devices: [], scenes: [],
      connectionMode: "xiaomiCloud" as const, dualSourceEnabled: false,
      hiddenDevices: closePlan.hiddenIndexedDevices,
    };

    // Both the raw did and the account-scoped id of a closed cover must name the closed type.
    for (const target of ["curtain", `${account.id}/curtain`]) {
      assert.match(
        evaluateDeviceEntityWriteGate({ targetKind: "device", targetIdOrEntityId: target, resolvedActiveDeviceId: null, context, rejectUnknown: true }) ?? "",
        /该设备类型已关闭/,
        target,
      );
      assert.match(
        evaluateIntentsWriteGate({
          intents: [{ targetId: target, operation: { kind: "power", isOn: false } }], context,
        }) ?? "",
        /该设备类型已关闭/,
        target,
      );
    }
    // Voice resolves the hidden card through a stub and then hits the same gate.
    const previousLanguage = currentLanguage();
    setLanguage("zh-Hans");
    try {
      assert.match(evaluateDisabledUtteranceGate({ utterance: "关闭客厅灯", context }) ?? "", /该设备类型已关闭/);
      // ...and without the index the same utterance never resolves to a target at all.
      assert.equal(evaluateDisabledUtteranceGate({ utterance: "关闭客厅灯", context: { ...context, hiddenDevices: undefined } }), null);
    } finally {
      setLanguage(previousLanguage);
    }
    // The URL gate only gets settings, so the host hands it the same index.
    assert.match(
      evaluateDisabledDeviceUrlGate(
        "curtain",
        { connectionMode: "xiaomiCloud", miSession: session, hiddenDevices: closePlan.hiddenIndexedDevices },
        storage,
      ) ?? "",
      /该设备类型已关闭/,
    );

    // Without the hidden index every one of them falls back to "no such device".
    const bare = { ...context, hiddenDevices: undefined };
    assert.match(
      evaluateDeviceEntityWriteGate({ targetKind: "device", targetIdOrEntityId: "curtain", resolvedActiveDeviceId: null, context: bare, rejectUnknown: true }) ?? "",
      /未找到|不存在/,
    );
    assert.equal(
      evaluateDisabledDeviceUrlGate("curtain", { connectionMode: "xiaomiCloud", miSession: session }, storage),
      null,
    );
  });
});

describe("Mi device-type pruning: pinned cards, word edges and battery kinds (P3a-W r2)", () => {
  const ACCOUNT = "acc1";
  const planStarred = (
    categories: readonly DeviceCategoryID[],
    safetySignals: readonly SafetySignalKind[],
    starredDeviceIds: readonly string[],
  ) => buildMiotTypePrunePlan({
    rawDevices: devices,
    specs,
    selection: selection(categories),
    connectionScope: SCOPE,
    safetySignals,
    starredDeviceIds,
  });

  it("keeps a pinned hidden card as a topology record and reads nothing for it", () => {
    // The panel stores the id it drew: `<accountId>/<did>` on a multi-account host, the bare did on a
    // single-account one. Both must match.
    const plan = planStarred(["plug"], ["starredOffline"], [`${ACCOUNT}/light`, "tank"]);
    for (const did of ["light", "tank"] as const) {
      assert.equal(plan.visibleDeviceIds.has(did), false, did);
      assert.ok(plan.safetyRetainedDeviceIds.has(did), did);
      // The offline alert reads `isOnline`, which the record already carries: no getProps key.
      assert.deepEqual(readsOf(plan.readKeys, did), [], did);
      assert.ok(plan.safetyRecords.some((record) => record.did === did), did);
      assert.ok(plan.hiddenIndexedDevices.some((device) => device.id === did), did);
    }
    // The topology record still synthesizes, so the alert engine sees the device's own online state.
    const retired = plan.safetyRecords.find((record) => record.did === "light")!;
    const home = MiotSynthesizer.synthesize([retired], [], specs, new Map());
    assert.equal(home.devices.find((device) => device.id === "light")?.isOnline, true);

    // Everything else that only a signal could keep is gone, and nothing else is read.
    for (const did of ["curtain", "leak", "contact"] as const) {
      assert.equal(plan.safetyRetainedDeviceIds.has(did), false, did);
    }
    assert.deepEqual(
      readIds(plan.readKeys).sort(),
      readIds(plan.readKeys.filter((key) => key.did === "plug")).sort(),
    );
  });

  it("matches a pin's namespace against the plan's own account", () => {
    // `acc2/light` is another account's card: the same raw did there is a different device.
    const otherAccount = planStarred(["plug"], ["starredOffline"], ["acc2/light"]);
    assert.equal(otherAccount.safetyRetainedDeviceIds.has("light"), false);
    assert.equal(otherAccount.skippedDeviceIds.has("light"), true);

    // A cloud account id already carries the `mi:` prefix (`mi:cn:<hash>`), and its namespace is
    // that same id, not a second `mi:` in front of it.
    const scope = "mi:cn:abc123";
    const cloudPlan = buildMiotTypePrunePlan({
      rawDevices: devices,
      specs,
      selection: selection(["plug"], [scope]),
      connectionScope: scope,
      safetySignals: ["starredOffline"],
      starredDeviceIds: [`${scope}/light`],
    });
    assert.ok(cloudPlan.safetyRetainedDeviceIds.has("light"));
    assert.deepEqual(readsOf(cloudPlan.readKeys, "light"), []);
  });

  it("still reads a pinned card that a signal of its own keeps", () => {
    const plan = planStarred(["plug"], ["starredOffline", "leak"], [`${ACCOUNT}/leak`]);
    assert.ok(plan.safetyRetainedDeviceIds.has("leak"));
    assert.ok(readsOf(plan.readKeys, "leak").length > 0);
    // ...and the offline alert stays off while its switch is off, pinned or not.
    const off = planStarred(["plug"], ["leak"], [`${ACCOUNT}/light`]);
    assert.equal(off.safetyRetainedDeviceIds.has("light"), false);
  });

  it("changes nothing while every type is enabled, pinned cards included", () => {
    const plain = planStarred(DEVICE_CATEGORY_IDS, ALL_SENSOR_SIGNALS, []);
    const pinned = planStarred(DEVICE_CATEGORY_IDS, ALL_SENSOR_SIGNALS, [`${ACCOUNT}/light`]);
    assert.deepEqual(readIds(pinned.readKeys).sort(), readIds(plain.readKeys).sort());
    assert.deepEqual([...pinned.hiddenIndexedDevices], []);
  });

  it("matches the short alert tokens on word edges only", () => {
    const strict = (text: string): string[] =>
      inferSensorAlertKindsFromMetadata(text, { wordBoundedShortTokens: true });
    // The reviewed collisions: a token inside a longer word never names a sensor.
    assert.deepEqual(strict("Expiration"), []);
    assert.deepEqual(strict("Indoor"), []);
    assert.deepEqual(strict("Milkshake"), []);
    // Real metadata still matches, because `-` and `_` are word separators.
    assert.deepEqual(strict("door-dect"), ["contact"]);
    assert.deepEqual(strict("pir-state"), ["motion"]);
    assert.deepEqual(strict("shake-sensor"), ["vibration"]);
    assert.deepEqual(strict("contact-state"), ["contact"]);
    assert.deepEqual(strict("water-leak"), ["leak"]);
    // Evaluation keeps the substring form, so an alert that fires today never disappears.
    assert.deepEqual(inferSensorAlertKindsFromMetadata("Expiration"), ["motion"]);
  });

  it("keeps a water-leak alert for leak sensors, not for an appliance's leakage code", () => {
    const plan = corpusPlan(["light"], ["leak"]);
    const models = new Set([...plan.safetyRetainedDeviceIds].map(modelForPlanId));
    assert.ok(models.has("bkxh.flood.yf02"));
    // `Leakage-current` on an EV charger is electrical, and `In Gas Leakage Alarm` is a gas code.
    assert.equal(models.has("careco.evc.a07a01"), false);
    assert.equal(models.has("bkxh.sensor_gas.s2"), false);
  });

  it("never reads a value label from a card that renders no facets", () => {
    // `viomi.hood.c26` labels a fan speed "GasStove"; only a builder-less card surfaces value labels.
    const gas = corpusPlan(["light"], ["gas"]);
    assert.equal(new Set([...gas.safetyRetainedDeviceIds].map(modelForPlanId)).has("viomi.hood.c26"), false);
    assert.ok(new Set([...gas.safetyRetainedDeviceIds].map(modelForPlanId)).has("bkxh.sensor_gas.s2"));
    // A microwave's `CookingOpenDoor` status is a door state, not a contact sensor.
    const contact = corpusPlan(["light"], ["contact"]);
    const contactModels = new Set([...contact.safetyRetainedDeviceIds].map(modelForPlanId));
    assert.equal(contactModels.has("chunmi.microwave.cmwb3"), false);
    assert.ok(contactModels.has("bkxh.magnet.yf01"));
  });

  it("keeps the low-battery read only on the kinds that publish a battery percentage", () => {
    const plan = corpusPlan(["light"], ["lowBattery"]);
    assert.ok(plan.safetyRetainedDeviceIds.size > 0);
    for (const id of plan.safetyRetainedDeviceIds) {
      const indexed = plan.hiddenIndexedDevices.find((device) => device.id === id);
      assert.ok(indexed, id);
      assert.ok(["sensor", "cover", "vacuum"].includes(indexed.category), `${modelForPlanId(id)}: ${indexed.category}`);
    }
    // A water-leak sensor's own card kind is `sensor`, so the battery switch still reaches it.
    assert.ok(plan.safetyRetainedDeviceIds.size > 1);
  });
});
