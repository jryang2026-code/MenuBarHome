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
import { buildMiotTypePrunePlan, miotSafetySignalsForSensorPolicy } from "../src/core/miotTypePruning.js";
import {
  createDefaultSensorAlertPolicy, evaluateSensorAlerts, inferSensorAlertKindsFromMetadata,
} from "../src/core/safetyAndHealth.js";
import type { SmartDevice } from "../src/core/models.js";
import { makeMiAccount, mergeMiAccountSnapshots, refreshMiAccountsConcurrently, type AccountChildSnapshot } from "../src/core/miAccountsStore.js";
import { buildIndexedCapabilityDevices, resolveMiAccountSelectionState } from "../src/core/miAccountControl.js";
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
    const { merged, children } = await refreshMiAccountsConcurrently({
      accounts: [account],
      transport,
      specResolver: new MiotSpecResolver(transport, specs),
      prune: { selection: selection(["light"], [account.id]), safetySignals: [...ALL_SENSOR_SIGNALS] },
      clientFactory: () => client as never,
    });

    // Only the kept type is a card; the curtain is neither a card nor a read.
    assert.deepEqual(merged.home.devices.map((device) => device.id), ["light"]);
    assert.equal(readKeys.some((id) => id.startsWith("curtain.")), false);
    // The leak sensor keeps the one read its alert needs and rides along for evaluation only.
    assert.ok(readKeys.includes("leak.2.1006"));
    const child = children[account.id] as AccountChildSnapshot;
    assert.deepEqual((child.safetyDevices ?? []).map((device) => device.id).sort(), ["contact", "gas", "leak", "lock", "smoke", "tank"]);
    assert.equal(child.home.devices.some((device) => device.id === "leak"), false);
    assert.deepEqual(merged.safetyDevices?.map((device) => device.id).sort(), ["contact", "gas", "leak", "lock", "smoke", "tank"]);

    // A disconnected account's stale alert devices never reach the merged evaluation set.
    const offline = mergeMiAccountSnapshots([account], {
      [account.id]: { ...child, status: { kind: "disconnected", reason: "offline" } },
    });
    assert.deepEqual(offline.safetyDevices ?? [], []);
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
