import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import {
  DEVICE_CATEGORY_CARD_KINDS, DEVICE_CATEGORY_IDS, DEVICE_CATEGORY_PRESETS, DEVICE_CATEGORY_PRESET_IDS,
  NON_CAMERA_DEVICE_CATEGORY_IDS, deviceCategoryForDevice,
  type DeviceCategoryID, type DeviceCategoryPresetID,
} from "../src/core/capabilityManifest.js";
import { devicePrimaryEntityId, type SmartDevice, type SynthesizedHome } from "../src/core/models.js";
import { deviceCategory } from "../src/core/assistant/deviceCategory.js";
import { miotShortName, parseMiotDeviceSpec, type MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { propKeyString, type MiDeviceRecord } from "../src/core/miCloud/client.js";
import { buildMiotTypePrunePlan } from "../src/core/miotTypePruning.js";
import { buildHaTypePrunePlan } from "../src/core/haTypePruning.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import {
  evaluateControlTargetGate, type CapabilitySelection, type SafetySignalKind,
} from "../src/core/capabilityReferenceVerdict.js";
import { evaluateSensorAlerts } from "../src/core/safetyAndHealth.js";

// The shared corpus both platforms read: `Tests/Fixtures/capability_selection_golden.json`. P3c-W
// owns the `deviceTypeMapping` section; the macOS twin (P3c-M) reads the same cases from
// `GoldenCorpusTests.swift`. A case names its input — a MIoT model whose shared spec publishes a
// service, or HA entity states — and the expected manifest category; each end draws its own card
// shape from that input, so nothing here pins a Windows-only `DeviceKind`.
interface HAStateRow { readonly entity_id: string; readonly state: string; readonly attributes: Record<string, unknown> }
interface HAInput {
  readonly source: "home-assistant";
  readonly device: { readonly name: string; readonly model: string };
  readonly states: readonly HAStateRow[];
}
interface MiotInput { readonly source: "xiaomi-cloud"; readonly model: string; readonly service?: string; readonly name: string }
interface FixtureSelection {
  readonly enabledConnections: CapabilitySelection["enabledConnections"];
  readonly enabledConnectionScopes: readonly string[];
  readonly enabledFeatures: CapabilitySelection["enabledFeatures"];
  readonly preset: DeviceCategoryPresetID;
}
interface ExpectedCard {
  readonly id?: string; readonly category: DeviceCategoryID;
  readonly controlDid?: string; readonly controlSiid?: number; readonly controlEntityId?: string;
}
interface PropRef { readonly siid: number; readonly piid: number }
interface FixtureCorpus {
  readonly deviceTypeMapping: {
    readonly presets: readonly { readonly id: DeviceCategoryPresetID; readonly categories: readonly DeviceCategoryID[] }[];
    readonly cardCases: readonly { readonly id: string; readonly input: HAInput | MiotInput; readonly expectedCategory: DeviceCategoryID }[];
    readonly mixedTypeCases: readonly ({
      readonly id: string; readonly expectedCards: readonly ExpectedCard[];
      readonly expectedFacetSiids?: readonly number[];
    } & (
      | {
          readonly source: "xiaomi-cloud"; readonly did: string; readonly name: string; readonly model?: string;
          readonly services?: readonly { readonly model: string; readonly service: string; readonly iid: number }[];
        }
      | HAInput
    ))[];
    readonly splitCardCases: readonly ({ readonly id: string; readonly expectedCards: readonly ExpectedCard[] } & (
      | {
          readonly source: "xiaomi-cloud"; readonly model: string; readonly service: string;
          readonly serviceIids: readonly number[]; readonly name: string;
          readonly did?: string; readonly parentDid?: string;
          readonly keys?: readonly { readonly did: string; readonly siid: number }[];
        }
      | HAInput
    ))[];
    readonly typeIndexHome: {
      readonly xiaomiCloud: {
        readonly connectionScope: string;
        readonly records: readonly { readonly did: string; readonly name: string; readonly model: string }[];
      };
      readonly homeAssistant: { readonly connectionScope: string } & Omit<HAInput, "source">;
    };
    readonly leakCases: readonly {
      readonly id: string; readonly selection: FixtureSelection; readonly safetySignals: readonly SafetySignalKind[];
      readonly leakDid: string; readonly alertKey: PropRef; readonly alertValue: unknown;
      readonly expectedAvailableDids: readonly string[]; readonly expectedRetainedDids: readonly string[];
      readonly expectedLeakReadKeys: readonly PropRef[]; readonly expectLeakAlert: boolean;
    }[];
    readonly zeroWriteCases: readonly {
      readonly id: string;
      readonly target: { readonly source: "xiaomi-cloud"; readonly did: string } | { readonly source: "home-assistant"; readonly entityId: string };
      readonly selection: FixtureSelection; readonly safetySignals: readonly SafetySignalKind[];
      readonly expectedMappedCategory: DeviceCategoryID | null;
      readonly expectedAllowed: boolean; readonly expectedWriteCount: number;
      readonly expectedRejectionCode: string | null;
    }[];
  };
}

const corpus = JSON.parse(
  readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/capability_selection_golden.json"), "utf8"),
) as FixtureCorpus;
const mapping = corpus.deviceTypeMapping;

const rawSpecs = JSON.parse(
  readFileSync(resolve(process.cwd(), "../Tests/Fixtures/miot_coverage_specs.json"), "utf8"),
) as Record<string, unknown>;

const ALL_TYPES: CapabilitySelection = {
  enabledConnections: ["xiaomi-cloud", "home-assistant"], enabledConnectionScopes: ["mi:acc1"],
  enabledFeatures: [], enabledCategories: [...DEVICE_CATEGORY_IDS],
};

const selectionOf = (fixture: FixtureSelection): CapabilitySelection => {
  const preset = mapping.presets.find((candidate) => candidate.id === fixture.preset);
  assert.ok(preset, `fixture preset ${fixture.preset}`);
  return {
    enabledConnections: [...fixture.enabledConnections],
    enabledConnectionScopes: [...fixture.enabledConnectionScopes],
    enabledFeatures: [...fixture.enabledFeatures],
    enabledCategories: [...preset.categories],
  };
};

const spec = (model: string): MiotDeviceSpec => {
  const parsed = parseMiotDeviceSpec(rawSpecs[model]);
  assert.ok(parsed, `shared MIoT spec ${model}`);
  return parsed;
};

/** One raw service of a shared spec, optionally moved to another iid so specs can be merged. */
const rawService = (model: string, short: string, iid?: number): Record<string, unknown> => {
  const raw = rawSpecs[model] as { services: Array<Record<string, unknown>> };
  const found = raw.services.find((service) => miotShortName(String(service.type)) === short);
  assert.ok(found, `${model} publishes a ${short} service`);
  return iid === undefined ? found : { ...found, iid };
};

/** A spec that publishes `services`, each copied from a shared spec, under the first one's type. */
const mergedSpec = (typeModel: string, services: readonly Record<string, unknown>[]): MiotDeviceSpec => {
  const parsed = parseMiotDeviceSpec({
    type: (rawSpecs[typeModel] as { type: string }).type, description: "merged", services,
  });
  assert.ok(parsed);
  return parsed;
};

const record = (did: string, name: string, model: string, extra: Partial<MiDeviceRecord> = {}): MiDeviceRecord => ({
  did, name, model, isOnline: true, specType: null, ...extra,
});

const synthesizeHA = (deviceId: string, input: Omit<HAInput, "source">): SynthesizedHome =>
  HomeAssistantSynthesizer.synthesize({
    areas: [{ area_id: "home", name: "家" }],
    devices: [{ id: deviceId, name: input.device.name, area_id: "home", model: input.device.model }],
    entities: input.states.map((row) => ({ entity_id: row.entity_id, device_id: deviceId })),
    states: input.states,
  });

const synthesizeMiot = (
  records: readonly MiDeviceRecord[], specs: Record<string, MiotDeviceSpec>, values = new Map<string, unknown>(),
): SynthesizedHome => MiotSynthesizer.synthesize(records, [], specs, values);

/** `miot:<did>:<siid>` → its parts, for a card's control address. */
const miotAddress = (entityId: string | null): { did: string; siid: number } | null => {
  const match = /^miot:(.+):(\d+)$/.exec(entityId ?? "");
  return match ? { did: match[1]!, siid: Number(match[2]) } : null;
};

const assertCards = (home: SynthesizedHome, expected: readonly ExpectedCard[], label: string): void => {
  assert.equal(home.devices.length, expected.length, `${label}: card count`);
  const entityIds = home.devices.map((device) => devicePrimaryEntityId(device));
  assert.equal(new Set(entityIds).size, entityIds.length, `${label}: every card addresses its own entity`);
  expected.forEach((want, index) => {
    const card = home.devices[index]!;
    if (want.id !== undefined) assert.equal(card.id, want.id, `${label}[${index}] id`);
    assert.equal(deviceCategoryForDevice(card), want.category, `${label}[${index}] category`);
    const entityId = devicePrimaryEntityId(card);
    if (want.controlEntityId !== undefined) assert.equal(entityId, want.controlEntityId, `${label}[${index}] entity`);
    if (want.controlSiid !== undefined) {
      const address = miotAddress(entityId);
      assert.ok(address, `${label}[${index}] has a MIoT address, got ${entityId}`);
      assert.equal(address.siid, want.controlSiid, `${label}[${index}] siid`);
      if (want.controlDid !== undefined) assert.equal(address.did, want.controlDid, `${label}[${index}] did`);
    }
  });
};

describe("Windows device-type mapping (P3c-W)", () => {
  it("shares the presets with macOS and covers every approved type", () => {
    // Both ends must answer the same lists: the corpus is the only owner of "which categories".
    assert.deepEqual(
      mapping.presets.map((preset) => preset.id).sort(),
      [...DEVICE_CATEGORY_PRESET_IDS].sort(),
    );
    for (const preset of mapping.presets) {
      assert.deepEqual(
        [...preset.categories].sort(),
        [...DEVICE_CATEGORY_PRESETS[preset.id]].sort(),
        preset.id,
      );
    }
    // 「只用灯和开关」 is a category list, so a wall switch drawn as a plug card is in it too.
    assert.deepEqual([...DEVICE_CATEGORY_PRESETS.lightAndSwitch], ["light", "plug"]);
    assert.deepEqual([...DEVICE_CATEGORY_PRESETS.allSupportedTypes], [...DEVICE_CATEGORY_IDS]);

    const covered = new Set(mapping.cardCases.map((c) => c.expectedCategory));
    assert.deepEqual([...covered].sort(), [...DEVICE_CATEGORY_IDS].sort());
    for (const category of DEVICE_CATEGORY_IDS) assert.ok(DEVICE_CATEGORY_CARD_KINDS[category].length > 0, category);
    // The camera card maps here like any other; only its teardown is P3c-CW.
    assert.equal(NON_CAMERA_DEVICE_CATEGORY_IDS.includes("camera"), false);
    assert.equal(NON_CAMERA_DEVICE_CATEGORY_IDS.length, DEVICE_CATEGORY_IDS.length - 1);
  });

  it("maps every shared input through the synthesizer and the one classifier", () => {
    for (const c of mapping.cardCases) {
      let card: SmartDevice;
      let planned: DeviceCategoryID | undefined;
      if (c.input.source === "home-assistant") {
        const home = synthesizeHA(`d-${c.id}`, c.input);
        assert.equal(home.devices.length, 1, `${c.id}: one card`);
        card = home.devices[0]!;
        planned = buildHaTypePrunePlan({
          devices: home.devices, selection: ALL_TYPES, connectionScope: "ha:test", safetySignals: [],
        }).categoryByDeviceId.get(card.id);
      } else {
        const input = c.input;
        const deviceSpec = spec(input.model);
        if (input.service !== undefined) {
          assert.ok(deviceSpec.services.some((s) => miotShortName(s.type) === input.service), `${c.id}: spec has ${input.service}`);
        }
        const raw = record(`did-${c.id}`, input.name, input.model);
        const home = synthesizeMiot([raw], { [input.model]: deviceSpec });
        assert.equal(home.devices.length, 1, `${c.id}: one card`);
        card = home.devices[0]!;
        planned = buildMiotTypePrunePlan({
          rawDevices: [raw], specs: { [input.model]: deviceSpec }, selection: ALL_TYPES,
          connectionScope: "mi:acc1", safetySignals: [],
        }).categoryByDeviceId.get(card.id);
      }
      assert.equal(deviceCategoryForDevice(card), c.expectedCategory, c.id);
      // The prune plan classifies the same input the same way, before any value is read.
      assert.equal(planned, c.expectedCategory, `${c.id}: prune plan`);
    }
  });

  it("never lets a name or the online state turn a water heater into a valve", () => {
    const online = mapping.cardCases.find((c) => c.id === "ha_water_heater_named_after_a_gas_valve_online")!;
    const offline = mapping.cardCases.find((c) => c.id === "ha_water_heater_named_after_a_gas_valve_offline")!;
    const cards = [online, offline].map((c) => synthesizeHA("d-water-heater", c.input as HAInput).devices[0]!);
    assert.equal(cards[0]!.isOnline, true);
    assert.equal(cards[1]!.isOnline, false);
    for (const card of cards) {
      assert.equal(card.kind.kind, "appliance");
      assert.equal(deviceCategoryForDevice(card), "appliance", `online=${card.isOnline}`);
      // The assistant reads the same shape check, so it never offers a valve intent for it either.
      assert.notEqual(deviceCategory(card), "valve", `assistant online=${card.isOnline}`);
    }
  });

  it("keeps a mixed-type device one card with its secondary services on it", () => {
    for (const c of mapping.mixedTypeCases) {
      if (c.source === "home-assistant") {
        // The second domain folds into the one card and never reclassifies or splits it.
        assertCards(synthesizeHA(`d-${c.id}`, c), c.expectedCards, c.id);
        continue;
      }
      const model = c.model ?? c.services![0]!.model;
      const deviceSpec = c.services === undefined
        ? spec(model)
        : mergedSpec(model, c.services.map((s) => rawService(s.model, s.service, s.iid)));
      const home = synthesizeMiot([record(c.did, c.name, model)], { [model]: deviceSpec });
      assertCards(home, c.expectedCards, c.id);
      const facetSiids = (home.deviceFacets?.[c.did] ?? []).map((facet) => miotAddress(facet.target?.entityId ?? null)?.siid);
      for (const siid of c.expectedFacetSiids ?? []) {
        assert.ok(facetSiids.includes(siid), `${c.id}: siid ${siid} stays on the card, got ${facetSiids.join(",")}`);
      }
    }
  });

  it("splits every key and track into its own card of the same type", () => {
    for (const c of mapping.splitCardCases) {
      if (c.source === "home-assistant") {
        assertCards(synthesizeHA(`d-${c.id}`, c), c.expectedCards, c.id);
        continue;
      }
      // The spec publishes the same service once per key or track, as the real devices do.
      const deviceSpec = mergedSpec(c.model, c.serviceIids.map((iid) => rawService(c.model, c.service, iid)));
      const records = c.keys === undefined
        ? [record(c.did!, c.name, c.model)]
        : [
            record(c.parentDid!, c.name, c.model),
            ...c.keys.map((key) => record(key.did, `${c.name} ${key.did}`, c.model, {
              splitParentDid: c.parentDid!, splitSiid: key.siid,
            })),
          ];
      const home = synthesizeMiot(records, { [c.model]: deviceSpec });
      assertCards(home, c.expectedCards, c.id);
      const plan = buildMiotTypePrunePlan({
        rawDevices: records, specs: { [c.model]: deviceSpec }, selection: ALL_TYPES,
        connectionScope: "mi:acc1", safetySignals: [],
      });
      // The prune plan sees the same cards: same ids, same type, the parent draws nothing.
      assert.deepEqual([...plan.categoryByDeviceId.keys()].sort(), home.devices.map((d) => d.id).sort(), c.id);
    }
  });

  it("leaves the read plan untouched when every type is enabled", () => {
    // "All types on" must be the pre-P3c path: every card drawn, every key read, nothing skipped.
    const models = {
      curtain: "090615.curtain.1mcu01",
      light: "miot.light.hyz05",
      plug: "090615.plug.cmp86",
      fan: "123888.fan.1121",
      leak: "bkxh.flood.yf02",
    } as const;
    const specs = Object.fromEntries(Object.values(models).map((model) => [model, spec(model)]));
    const devices = Object.entries(models).map(([did, model]) => record(did, did, model));
    const plan = buildMiotTypePrunePlan({
      rawDevices: devices, specs,
      selection: { ...ALL_TYPES, enabledCategories: [...DEVICE_CATEGORY_PRESETS.allSupportedTypes] },
      connectionScope: "mi:acc1", safetySignals: ["leak"],
    });
    const legacyReads = devices.flatMap((device) => {
      const deviceSpec = specs[device.model]!;
      return [
        ...MiotSynthesizer.requiredProps(device, deviceSpec),
        ...MiotSynthesizer.facetProps(device, deviceSpec),
      ].map((key) => `${key.did}|${key.siid}|${key.piid}`);
    });
    assert.deepEqual(
      plan.readKeys.map((key) => `${key.did}|${key.siid}|${key.piid}`).sort(),
      [...new Set(legacyReads)].sort(),
    );
    assert.deepEqual([...plan.skippedDeviceIds], []);
    assert.deepEqual([...plan.categoryByDeviceId.keys()].sort(), devices.map((device) => device.did).sort());
  });

  // The fixed assertions read their index from the real prune plans of one shared home.
  const home = mapping.typeIndexHome;
  const miRecords = home.xiaomiCloud.records.map((r) => record(r.did, r.name, r.model));
  const miSpecs = Object.fromEntries(miRecords.map((r) => [r.model, spec(r.model)]));
  const haCards = synthesizeHA("d-type-index", home.homeAssistant).devices;
  const prunePlans = (selection: CapabilitySelection, safetySignals: readonly SafetySignalKind[]) => ({
    mi: buildMiotTypePrunePlan({
      rawDevices: miRecords, specs: miSpecs, selection, connectionScope: home.xiaomiCloud.connectionScope, safetySignals,
    }),
    ha: buildHaTypePrunePlan({
      devices: haCards, selection, connectionScope: home.homeAssistant.connectionScope, safetySignals,
    }),
  });

  it("keeps reading and alerting a leak while the sensor type is closed", () => {
    for (const c of mapping.leakCases) {
      const selection = selectionOf(c.selection);
      assert.equal(selection.enabledCategories.includes("sensor"), false, c.id);
      const { mi } = prunePlans(selection, c.safetySignals);
      assert.equal(mi.categoryByDeviceId.get(c.leakDid), "sensor", c.id);
      assert.deepEqual([...mi.visibleDeviceIds].sort(), [...c.expectedAvailableDids].sort(), c.id);
      assert.deepEqual([...mi.safetyRetainedDeviceIds].sort(), [...c.expectedRetainedDids].sort(), c.id);
      // The closed leak sensor reads only what its alert needs — or nothing once the alert is off.
      const leakReads = mi.readKeys.filter((key) => key.did === c.leakDid).map((key) => `${key.siid}.${key.piid}`);
      assert.deepEqual(leakReads.sort(), c.expectedLeakReadKeys.map((key) => `${key.siid}.${key.piid}`).sort(), c.id);
      assert.equal(mi.visibleRecords.some((r) => r.did === c.leakDid), false, `${c.id}: never on the panel`);

      // Only the alert evaluation sees the retained card, synthesized from the retained reads.
      const values = new Map<string, unknown>();
      const alertKey = { did: c.leakDid, ...c.alertKey };
      if (mi.readKeys.some((key) => propKeyString(key) === propKeyString(alertKey))) {
        values.set(propKeyString(alertKey), c.alertValue);
      }
      const evaluated = synthesizeMiot(mi.safetyRecords, miSpecs, values);
      const result = evaluateSensorAlerts(evaluated.devices, {}, 1_700_000_000_000, {
        enabled: { leak: c.safetySignals.includes("leak") }, onlyWhenAway: false, includesAway: true,
      }, { deviceFacets: evaluated.deviceFacets ?? {} });
      assert.equal(result.alerts.length > 0, c.expectLeakAlert, c.id);
    }
  });

  it("rejects a hidden target from its mapped type with zero writes", () => {
    for (const c of mapping.zeroWriteCases) {
      const selection = selectionOf(c.selection);
      const { mi, ha } = prunePlans(selection, c.safetySignals);
      const index = [...mi.hiddenIndexedDevices, ...ha.hiddenIndexedDevices];
      const targetId = c.target.source === "xiaomi-cloud"
        ? c.target.did
        : haCards.find((card) => devicePrimaryEntityId(card) === (c.target as { entityId: string }).entityId)?.id
          ?? c.target.entityId;
      const mapped = mi.categoryByDeviceId.get(targetId) ?? ha.categoryByDeviceId.get(targetId) ?? null;
      assert.equal(mapped, c.expectedMappedCategory, c.id);
      const verdict = evaluateControlTargetGate({
        targetKind: "device", targetId, candidateIds: [], selection, devices: index,
      });
      assert.equal(verdict.allowed, c.expectedAllowed, c.id);
      assert.equal(verdict.writeCount, c.expectedWriteCount, c.id);
      assert.equal(verdict.rejectionReason?.code ?? null, c.expectedRejectionCode, c.id);
      // The gate's reason is the mapping's own answer, from the same index.
      if (mapped !== null) assert.equal(verdict.rejectionReason?.disabledCategory, mapped, c.id);
    }
  });
});
