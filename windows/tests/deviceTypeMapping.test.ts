import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import {
  DEVICE_CATEGORY_CARD_KINDS, DEVICE_CATEGORY_IDS, DEVICE_CATEGORY_PRESETS, DEVICE_CATEGORY_PRESET_IDS,
  DEVICE_KIND_TO_CATEGORY, NON_CAMERA_DEVICE_CATEGORY_IDS,
  deviceCategoryForCardShape, deviceCategoryForDevice,
  type DeviceCategoryID, type DeviceCategoryPresetID,
} from "../src/core/capabilityManifest.js";
import {
  deviceCardShape, deviceCardShapeForKind,
  type DeviceCardShape, type DeviceKind, type SmartDevice,
} from "../src/core/models.js";
import { miotShortName, parseMiotDeviceSpec, type MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import type { MiDeviceRecord } from "../src/core/miCloud/client.js";
import { buildMiotTypePrunePlan } from "../src/core/miotTypePruning.js";
import { HomeAssistantSynthesizer } from "../src/core/homeAssistant.js";
import {
  evaluateControlTargetGate, partitionCapabilityDevices,
  type CapabilityIndexedDevice, type CapabilitySelection, type SafetySignalKind,
} from "../src/core/capabilityReferenceVerdict.js";
import { evaluateSensorAlerts } from "../src/core/safetyAndHealth.js";

// The shared corpus both platforms read: `Tests/Fixtures/capability_selection_golden.json`. P3c-W
// owns the `deviceTypeMapping` section; the macOS twin (P3c-M) reads the same cases from
// `GoldenCorpusTests.swift`, so a mapping change has to land on both ends with one assertion set.
interface FixtureCard {
  readonly kind: DeviceKind["kind"];
  readonly entityId: string;
  readonly model: string;
  readonly name: string;
  readonly symbolName?: string | null;
  readonly heats?: boolean;
  readonly temperatureWritable?: boolean;
  readonly availableModes?: readonly string[];
}
interface FixtureSelection {
  readonly enabledConnections: CapabilitySelection["enabledConnections"];
  readonly enabledConnectionScopes: readonly string[];
  readonly enabledFeatures: CapabilitySelection["enabledFeatures"];
  readonly preset: DeviceCategoryPresetID;
}
interface FixtureCorpus {
  readonly deviceTypeMapping: {
    readonly presets: readonly { readonly id: DeviceCategoryPresetID; readonly categories: readonly DeviceCategoryID[] }[];
    readonly cardCases: readonly {
      readonly id: string; readonly card: FixtureCard; readonly expectedCategory: DeviceCategoryID;
    }[];
    readonly mixedTypeCases: readonly {
      readonly id: string; readonly source: "xiaomi-cloud" | "home-assistant";
      readonly primaryModel?: string; readonly secondaryModel?: string; readonly model?: string;
      readonly name?: string; readonly entities?: readonly string[];
      readonly expectedCards: number; readonly expectedCategory: DeviceCategoryID;
      readonly expectedSecondaryCategory?: DeviceCategoryID;
      readonly expectedSecondaryCategories?: readonly DeviceCategoryID[];
    }[];
    readonly splitCardCases: readonly {
      readonly id: string; readonly source: "xiaomi-cloud" | "home-assistant";
      readonly model?: string; readonly parentDid?: string;
      readonly keys?: readonly { readonly did: string; readonly siid: number }[];
      readonly entities?: readonly string[];
      readonly expectedCategory: DeviceCategoryID;
    }[];
    readonly devices: readonly CapabilityIndexedDevice[];
    readonly leakCases: readonly {
      readonly id: string; readonly selection: FixtureSelection; readonly safetySignals: readonly SafetySignalKind[];
      readonly expectedAvailableDeviceIds: readonly string[];
      readonly expectedHiddenSafetyRetainedDeviceIds: readonly string[];
      readonly expectedSafetyEvaluationDeviceIds: readonly string[];
      readonly expectedReadPlanKeys: readonly string[];
      readonly expectLeakAlertWhenSensorTriggers: boolean;
    }[];
    readonly zeroWriteCases: readonly {
      readonly id: string; readonly targetKind: "device"; readonly targetId: string;
      readonly candidateIds: readonly string[]; readonly selection: FixtureSelection;
      readonly safetySignals: readonly SafetySignalKind[];
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

const depositShape = (id: string, card: FixtureCard): DeviceCardShape => ({
  id,
  kind: card.kind,
  entityId: card.entityId,
  model: card.model,
  name: card.name,
  symbolName: card.symbolName ?? null,
  heats: card.heats ?? false,
  temperatureWritable: card.temperatureWritable ?? false,
  availableModes: card.availableModes ?? [],
});

/** A card of `kind` with no hint at all: what a bare kind table would answer. */
const bareShape = (kind: DeviceKind["kind"]): DeviceCardShape => ({
  id: `bare:${kind}`, kind, entityId: "", model: "", name: "",
  symbolName: null, heats: false, temperatureWritable: false, availableModes: [],
});

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

/** One raw service of a shared spec, optionally moved to another iid so two specs can be merged. */
const rawService = (model: string, short: string, iid?: number): Record<string, unknown> => {
  const raw = rawSpecs[model] as { services: Array<Record<string, unknown>> };
  const found = raw.services.find((service) => miotShortName(String(service.type)) === short);
  assert.ok(found, `${model} publishes a ${short} service`);
  return iid === undefined ? found : { ...found, iid };
};

const record = (did: string, name: string, model: string, extra: Partial<MiDeviceRecord> = {}): MiDeviceRecord => ({
  did, name, model, isOnline: true, specType: null, ...extra,
});

describe("Windows device-type mapping (P3c-W)", () => {
  it("shares the presets with macOS and covers every approved card type", () => {
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
    // Every case's card kind can actually reach its category, and every category has a card kind.
    for (const c of mapping.cardCases) {
      const kinds: readonly DeviceKind["kind"][] = DEVICE_CATEGORY_CARD_KINDS[c.expectedCategory];
      assert.ok(kinds.includes(c.card.kind), c.id);
    }
    for (const category of DEVICE_CATEGORY_IDS) {
      const kinds: readonly DeviceKind["kind"][] = DEVICE_CATEGORY_CARD_KINDS[category];
      assert.ok(kinds.length > 0, category);
      const reachable = kinds.some(
        (kind) => deviceCategoryForCardShape(bareShape(kind)) === category,
      ) || covered.has(category);
      assert.ok(reachable, `unreachable category ${category}`);
    }
    // The camera card maps here like any other; only its teardown is P3c-CW.
    assert.equal(NON_CAMERA_DEVICE_CATEGORY_IDS.includes("camera"), false);
    assert.equal(NON_CAMERA_DEVICE_CATEGORY_IDS.length, DEVICE_CATEGORY_IDS.length - 1);
  });

  it("maps every shared card case through the one classifier", () => {
    for (const c of mapping.cardCases) {
      assert.equal(deviceCategoryForCardShape(depositShape(`case:${c.id}`, c.card)), c.expectedCategory, c.id);
    }

    // The two derivations that are not a card-kind lookup answer from the shape alone.
    const valveByName = depositShape("case:valve", {
      kind: "appliance", entityId: "miot:601:2", model: "custom.shutoff.x1", name: "燃气阀",
      temperatureWritable: false, availableModes: [],
    });
    assert.equal(deviceCategoryForCardShape(valveByName), "valve");
    // …and a shape that says nothing still gets the plain kind answer: `appliance` is not `valve`.
    assert.equal(deviceCategoryForCardShape(bareShape("appliance")), "appliance");
    for (const kind of Object.keys(DEVICE_KIND_TO_CATEGORY) as Array<DeviceKind["kind"]>) {
      assert.equal(deviceCategoryForCardShape(bareShape(kind)), DEVICE_KIND_TO_CATEGORY[kind], kind);
    }

    // `deviceCategoryForDevice` is the same classifier behind a synthesized device.
    const waterValve: SmartDevice = {
      id: "valve.water_main", name: "总水阀", roomId: "kitchen", roomName: "厨房",
      model: "tuya.valve", isOnline: true,
      kind: {
        kind: "appliance", entityId: "valve.water_main", isOn: false, powerPresent: true, powerWritable: true,
        currentMode: null, availableModes: [], modeWritable: false, targetTemperature: null, currentTemperature: null,
        minTemp: 0, maxTemp: 100, step: 1, temperatureWritable: false, statusText: null, faultText: null,
        remainingMinutes: null, startAction: null, pauseAction: null, stopAction: null,
        powerEntityId: "valve.water_main", modeEntityId: "valve.water_main", temperatureEntityId: "valve.water_main",
        light: null, fanLevel: null, currentHumidity: null, symbolName: null, roomReading: false, heats: false,
      },
    };
    assert.equal(deviceCategoryForDevice(waterValve), "valve");
    const humidifierAppliance: SmartDevice = {
      ...waterValve,
      id: "humidifier.guest", name: "客房加湿器", model: "custom.humidifier.x1",
      kind: {
        ...waterValve.kind as Extract<DeviceKind, { kind: "appliance" }>,
        entityId: "humidifier.guest", temperatureWritable: true, symbolName: "humidity.fill",
      },
    };
    assert.equal(deviceCategoryForDevice(humidifierAppliance), "fan");
    assert.deepEqual(deviceCardShape(waterValve), deviceCardShapeForKind(waterValve.kind, waterValve));
  });

  it("classifies the cards the synthesizers actually draw, mixed types included", () => {
    const allTypes: CapabilitySelection = {
      enabledConnections: ["xiaomi-cloud", "home-assistant"], enabledConnectionScopes: ["mi:acc1"],
      enabledFeatures: [], enabledCategories: [...DEVICE_CATEGORY_IDS],
    };
    const miotCards = (devices: readonly MiDeviceRecord[], specs: Record<string, MiotDeviceSpec>) => {
      const plan = buildMiotTypePrunePlan({
        rawDevices: devices, specs, selection: allTypes, connectionScope: "mi:acc1", safetySignals: [],
      });
      return { plan, cards: [...plan.categoryByDeviceId.entries()] };
    };
    // A fan with a light service: one card, the light stays a 更多设置 row, the type is the fan.
    const fanLight = mapping.mixedTypeCases.find((c) => c.primaryModel !== undefined)!;
    const primaryService = miotShortName((rawSpecs[fanLight.primaryModel!] as { type: string }).type);
    const secondaryService = miotShortName((rawSpecs[fanLight.secondaryModel!] as { type: string }).type);
    const merged = parseMiotDeviceSpec({
      type: (rawSpecs[fanLight.primaryModel!] as { type: string }).type,
      description: "mixed device",
      services: [rawService(fanLight.primaryModel!, primaryService), rawService(fanLight.secondaryModel!, secondaryService, 9)],
    });
    assert.ok(merged);
    const mixedRecord = record("3001", fanLight.name ?? "mixed", fanLight.primaryModel!);
    const mixed = miotCards([mixedRecord], { [fanLight.primaryModel!]: merged });
    assert.deepEqual(mixed.cards, [["3001", fanLight.expectedCategory]]);
    const mixedReads = MiotSynthesizer.planReadKeys(mixedRecord, merged);
    assert.equal(mixedReads.length, fanLight.expectedCards, "a mixed device draws one card");
    // The secondary service (moved to siid 9) is still read and drawn as facets on the same card.
    assert.ok(mixedReads[0]!.facets.some((key) => key.siid === 9), "secondary service stays on the card");

    // A speaker that also publishes lights, a curtain and an air conditioner: still one speaker.
    const speakerCase = mapping.mixedTypeCases.find((c) => c.model !== undefined)!;
    const speakerModel = speakerCase.model!;
    const speaker = miotCards([record("4001", speakerCase.name ?? "mixed", speakerModel)], { [speakerModel]: spec(speakerModel) });
    assert.deepEqual(speaker.cards, [["4001", speakerCase.expectedCategory]]);
    // Every secondary service lives on that one card, never as a card of its own.
    assert.equal(speaker.cards.length, 1, (speakerCase.expectedSecondaryCategories ?? []).join(","));

    // Home Assistant folds one registry device into one card: the primary domain wins the card (the
    // existing order), so the second domain is not a second card and never reclassifies it.
    const haCase = mapping.mixedTypeCases.find((c) => c.source === "home-assistant")!;
    const haEntities = haCase.entities!;
    const ha = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "bedroom", name: "卧室" }],
      devices: [{ id: "d-mixed", name: haCase.id, area_id: "bedroom", model: "test.mixed" }],
      entities: haEntities.map((entityId) => ({ entity_id: entityId, device_id: "d-mixed" })),
      states: haEntities.map((entityId) => ({
        entity_id: entityId,
        state: "on",
        attributes: entityId.startsWith("fan.") ? { percentage: 40 } : { brightness: 128 },
      })),
    });
    assert.equal(ha.devices.length, haCase.expectedCards, "one physical device, one card");
    assert.equal(deviceCategoryForDevice(ha.devices[0]!), haCase.expectedCategory);
  });

  it("keeps every split key and track its own card of the same type", () => {
    const switchCase = mapping.splitCardCases.find((c) => c.id === "multi_key_wall_switch_keeps_one_plug_card_per_key")!;
    const switchModel = switchCase.model!;
    const keys = switchCase.keys!;
    const switchPlan = buildMiotTypePrunePlan({
      rawDevices: [
        record(switchCase.parentDid!, "双键开关", switchModel),
        ...keys.map((key) => record(key.did, `双键开关 ${key.did}`, switchModel, {
          splitParentDid: switchCase.parentDid!, splitSiid: key.siid,
        })),
      ],
      specs: { [switchModel]: spec(switchModel) },
      selection: {
        enabledConnections: ["xiaomi-cloud"], enabledConnectionScopes: ["mi:acc1"],
        enabledFeatures: [], enabledCategories: [...DEVICE_CATEGORY_IDS],
      },
      connectionScope: "mi:acc1",
      safetySignals: [],
    });
    // The parent draws nothing; each key is its own plug card.
    assert.deepEqual([...switchPlan.categoryByDeviceId.keys()].sort(), keys.map((key) => key.did).sort());
    for (const key of keys) assert.equal(switchPlan.categoryByDeviceId.get(key.did), switchCase.expectedCategory, key.did);

    // A dual-track motor publishes two curtain services: one cover card per track, never one card
    // with both tracks.
    const curtainCase = mapping.splitCardCases.find((c) => c.id === "dual_track_curtain_keeps_one_cover_card_per_track")!;
    const curtainModel = curtainCase.model!;
    const dualTrack = parseMiotDeviceSpec({
      type: (rawSpecs[curtainModel] as { type: string }).type,
      description: "dual track",
      services: [rawService(curtainModel, "curtain"), rawService(curtainModel, "curtain", 5)],
    });
    assert.ok(dualTrack);
    const curtainPlan = buildMiotTypePrunePlan({
      rawDevices: [record("5001", "双轨窗帘", curtainModel)],
      specs: { [curtainModel]: dualTrack },
      selection: {
        enabledConnections: ["xiaomi-cloud"], enabledConnectionScopes: ["mi:acc1"],
        enabledFeatures: [], enabledCategories: [...DEVICE_CATEGORY_IDS],
      },
      connectionScope: "mi:acc1",
      safetySignals: [],
    });
    assert.equal(curtainPlan.categoryByDeviceId.size, 2);
    for (const category of curtainPlan.categoryByDeviceId.values()) assert.equal(category, curtainCase.expectedCategory);

    // Home Assistant splits a device with two covers per track as well.
    const haCover = mapping.splitCardCases.find((c) => c.id === "ha_double_cover_device_keeps_one_cover_card_per_track")!;
    const ha = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [{ id: "d-double-cover", name: "双轨窗帘", area_id: "living", model: "test.cover" }],
      entities: haCover.entities!.map((entityId) => ({ entity_id: entityId, device_id: "d-double-cover" })),
      states: haCover.entities!.map((entityId) => ({
        entity_id: entityId, state: "open", attributes: { current_position: 40, supported_features: 15 },
      })),
    });
    assert.equal(ha.devices.length, haCover.entities!.length);
    for (const device of ha.devices) assert.equal(deviceCategoryForDevice(device), haCover.expectedCategory, device.id);
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
      rawDevices: devices,
      specs,
      selection: {
        enabledConnections: ["xiaomi-cloud"], enabledConnectionScopes: ["mi:acc1"],
        enabledFeatures: [], enabledCategories: [...DEVICE_CATEGORY_PRESETS.allSupportedTypes],
      },
      connectionScope: "mi:acc1",
      safetySignals: ["leak"],
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

  it("keeps reading and alerting a leak while the sensor type is closed", () => {
    const leakCard: SmartDevice = {
      id: "sensor.kitchen_leak", name: "厨房水浸传感器", roomId: "kitchen", roomName: "厨房",
      model: "lumi.sensor_wleak.aq1", isOnline: true,
      kind: {
        kind: "sensor", temperature: null, humidity: null, battery: 90, statusText: "浸水告警", alertKind: "leak",
        safetyObservations: [{ entityId: "105.2.1", kind: "leak", alarming: true }],
      },
    };
    // The fixed assertion starts at the mapping: a flood sensor is the `sensor` type.
    assert.equal(deviceCategoryForDevice(leakCard), "sensor");

    for (const c of mapping.leakCases) {
      const selection = selectionOf(c.selection);
      assert.equal(selection.enabledCategories.includes("sensor"), false, c.id);
      const partition = partitionCapabilityDevices(mapping.devices, selection, { enabledSignals: c.safetySignals });
      assert.deepEqual(partition.availableDeviceIds, c.expectedAvailableDeviceIds, c.id);
      assert.deepEqual(partition.hiddenSafetyRetainedDeviceIds, c.expectedHiddenSafetyRetainedDeviceIds, c.id);
      assert.deepEqual(partition.safetyEvaluationDeviceIds, c.expectedSafetyEvaluationDeviceIds, c.id);
      assert.deepEqual(partition.readPlanKeys, c.expectedReadPlanKeys, c.id);
      // Only the alert evaluation sees the closed card; the panel never does.
      const evaluated = partition.safetyEvaluationDeviceIds.includes(leakCard.id) ? [leakCard] : [];
      const result = evaluateSensorAlerts(evaluated, {}, 1_700_000_000_000, {
        enabled: { leak: c.safetySignals.includes("leak") }, onlyWhenAway: false, includesAway: true,
      });
      assert.equal(result.alerts.length > 0, c.expectLeakAlertWhenSensorTriggers, c.id);
    }
  });

  it("rejects a hidden target from its mapped type with zero writes", () => {
    for (const c of mapping.zeroWriteCases) {
      const selection = selectionOf(c.selection);
      const indexed = mapping.devices.find((device) => device.id === c.targetId);
      if (c.expectedMappedCategory === null) {
        assert.equal(indexed, undefined, c.id);
      } else {
        // The gate's reason is the mapping's own answer, not a hand-written category.
        assert.equal(indexed?.category, c.expectedMappedCategory, c.id);
      }
      const verdict = evaluateControlTargetGate({
        targetKind: c.targetKind,
        targetId: c.targetId,
        candidateIds: [...c.candidateIds],
        selection,
        devices: mapping.devices,
      });
      assert.equal(verdict.allowed, c.expectedAllowed, c.id);
      assert.equal(verdict.writeCount, c.expectedWriteCount, c.id);
      assert.equal(verdict.rejectionReason?.code ?? null, c.expectedRejectionCode, c.id);
      if (c.expectedMappedCategory !== null) {
        assert.equal(verdict.rejectionReason?.disabledCategory, c.expectedMappedCategory, c.id);
      }
    }
  });
});
