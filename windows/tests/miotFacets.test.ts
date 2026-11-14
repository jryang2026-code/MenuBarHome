import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { isDeepStrictEqual } from "node:util";
import {
  DEVICE_PROFILES,
  buildMiotFacets,
  facetControls,
  isMiotAlertLabel,
  matchesMiotFacetPattern,
} from "../src/core/miCloud/facets.js";
import {
  MAXIMUM_PORTION_OPTIONS,
  isAdvancedWriteLocked,
  lockedControlIdForAlert,
  portionOptionsForControl,
  showsAdvancedViewOnlyCopy,
} from "../src/core/miCloud/feedAction.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { facetAlertText, facetTitle } from "../src/core/miotFacetText.js";
import { setLanguage } from "../src/core/i18n.js";
import type { MiotFacet } from "../src/core/miCloud/facets.js";
import { parseMiotDeviceSpec } from "../src/core/miCloud/spec.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";

// Same rule cases, fish tank, and coverage golden as Tests/MijiaCoreTests/MiotFacetsTests.swift (#303).
interface RuleCase {
  id: string;
  spec: unknown;
  expected: MiotFacet[];
}
interface ModelCase {
  model: string;
  expected: MiotFacet[];
}
interface Fixture {
  version: number;
  cases: RuleCase[];
  models: ModelCase[];
}
interface CoverageEntry {
  ids: string[];
  highValue: string[];
}
interface CoverageGolden {
  models: Record<string, CoverageEntry>;
}

const fixtures = resolve(process.cwd(), "../Tests/Fixtures");
const fixture = JSON.parse(readFileSync(resolve(fixtures, "miot_facets.json"), "utf8")) as Fixture;
const golden = JSON.parse(
  readFileSync(resolve(fixtures, "miot_facets_coverage_golden.json"), "utf8"),
) as CoverageGolden;
const rawSpecs = JSON.parse(readFileSync(resolve(fixtures, "miot_coverage_specs.json"), "utf8")) as Record<
  string,
  unknown
>;

function parseSpec(raw: unknown): MiotDeviceSpec {
  const spec = parseMiotDeviceSpec(raw);
  assert.ok(spec, "fixture spec parses");
  return spec;
}

function coverageSpecs(): [string, MiotDeviceSpec][] {
  return Object.entries(rawSpecs).map(([model, raw]) => [model, parseSpec(raw)]);
}

describe("MIoT facet engine (shared fixture)", () => {
  it("recognizes alert words without treating healthy labels or word fragments as faults", () => {
    for (const label of ["Low", "Low1", "Bockage", "Stuck Food", "Pump Fault", "水泵缺水"]) {
      assert.equal(isMiotAlertLabel(label), true, label);
    }
    for (const label of ["Flow", "No Faults", "Normal", "Allowed", "low2", "水Low水"]) {
      assert.equal(isMiotAlertLabel(label), false, label);
    }
  });

  it("ignores invalid alert values and keeps the existing English titles", () => {
    const spec = parseSpec({
      type: "urn:miot-spec-v2:device:fish-tank:00000000:fixture:1",
      services: [{
        iid: 2,
        type: "urn:miot-spec-v2:service:fish-tank:00000000:fixture:1",
        properties: [{
          iid: 1,
          type: "urn:miot-spec-v2:property:pump-alarm:00000000:fixture:1",
          description: "Pump alarm",
          format: "uint8",
          access: ["read"],
          "value-list": [{ value: 1, description: "Low" }],
        }],
      }],
    });
    const record = { did: "tank", name: "tank", model: "fixture.tank", isOnline: true, specType: null };
    for (const raw of [NaN, Infinity, -Infinity, Number.MAX_VALUE, "bad", "", null, true]) {
      const card = MiotSynthesizer.genericCard(record, spec, new Map([["tank.2.1", raw]]));
      assert.deepEqual(card?.kind.alerts, [], String(raw));
    }
    const card = MiotSynthesizer.genericCard(record, spec, new Map([["tank.2.1", 1]]));
    const control = card?.facets[0];
    assert.ok(control);
    setLanguage("en");
    try {
      assert.equal(facetTitle({ ...control, name: "brightness", title: "亮度" }), "Brightness");
      assert.equal(facetAlertText(control, "Low"), "Pump alarm：Low");
      assert.equal(facetAlertText({ ...control, title: null }, "Low"), "Pump alarm：Low");
    } finally {
      setLanguage("zh-Hans");
    }
  });

  it("matches every hand-written rule case", () => {
    for (const ruleCase of fixture.cases) {
      const actual = buildMiotFacets(parseSpec(ruleCase.spec));
      assert.ok(isDeepStrictEqual(actual, ruleCase.expected), `${ruleCase.id}: ${JSON.stringify(actual)}`);
    }
  });

  it("matches the fish tank facets and keeps high value small", () => {
    for (const modelCase of fixture.models) {
      const spec = parseSpec(rawSpecs[modelCase.model]);
      const actual = buildMiotFacets(spec);
      assert.ok(isDeepStrictEqual(actual, modelCase.expected), `${modelCase.model}: ${JSON.stringify(actual)}`);
      const highValue = actual.filter((facet) => facet.highValue);
      assert.ok(highValue.length <= 8, `${modelCase.model}: ${highValue.length}`);
      assert.ok(highValue.length < actual.length, `${modelCase.model}`);
    }
  });

  it("keeps the new high-risk services and device types closed", () => {
    const makeSpec = (deviceType: string, serviceName: string) =>
      parseSpec({
        type: `urn:miot-spec-v2:device:${deviceType}:00000000:fixture:1`,
        services: [
          {
            iid: 2,
            type: `urn:miot-spec-v2:service:${serviceName}:00000000:fixture:1`,
            properties: [
              {
                iid: 1,
                type: "urn:miot-spec-v2:property:on:00000000:fixture:1",
                format: "bool",
                access: ["read", "write"],
              },
            ],
          },
        ],
      });

    for (const serviceName of [
      "garbage-disposal",
      "disposal-service",
      "alertor",
      "alarm",
      "sterilizer",
      "baby-bottle-warmer",
      "multifunction-cooking-pot",
    ]) {
      const facet = buildMiotFacets(makeSpec("vendor", serviceName))[0];
      assert.ok(facet);
      assert.equal(facet.risk, "high", serviceName);
      assert.equal(facet.writesByDefault, false, serviceName);
    }

    for (const deviceType of ["germicidal-lamp", "alertor", "garbage-disposal"]) {
      const facet = buildMiotFacets(makeSpec(deviceType, "switch"))[0];
      assert.ok(facet);
      assert.equal(facet.risk, "high", deviceType);
      assert.equal(facet.writesByDefault, false, deviceType);
    }
  });

  it("drops every noise service and property across the coverage fixture", () => {
    for (const [model, spec] of coverageSpecs()) {
      for (const facet of buildMiotFacets(spec, DEVICE_PROFILES, model)) {
        if (matchesMiotFacetPattern(facet.serviceName, DEVICE_PROFILES.noise.services)) {
          // A noisy vendor service only survives through the named exceptions (#7).
          assert.ok(
            matchesMiotFacetPattern(facet.name, DEVICE_PROFILES.noise.keepInNoisyServices),
            `${model}: service ${facet.serviceName} property ${facet.name}`,
          );
        }
        assert.ok(
          !matchesMiotFacetPattern(facet.name, DEVICE_PROFILES.noise.properties),
          `${model}: property ${facet.name}`,
        );
      }
    }
  });

  it("gives every facet a stable id and constraints that match its kind", () => {
    for (const [model, spec] of coverageSpecs()) {
      const ids = new Set<string>();
      for (const facet of buildMiotFacets(spec, DEVICE_PROFILES, model)) {
        assert.ok(!ids.has(facet.id), `${model}: duplicate ${facet.id}`);
        ids.add(facet.id);
        switch (facet.kind) {
          case "toggle":
            assert.ok(facet.isWritable, `${model}: ${facet.id}`);
            assert.equal(facet.range, undefined, `${model}: ${facet.id}`);
            assert.equal(facet.options, undefined, `${model}: ${facet.id}`);
            break;
          case "select":
            assert.ok(facet.isWritable, `${model}: ${facet.id}`);
            assert.ok((facet.options?.length ?? 0) > 0, `${model}: ${facet.id}`);
            break;
          case "slider":
            assert.ok(facet.isWritable, `${model}: ${facet.id}`);
            assert.ok(facet.range, `${model}: ${facet.id}`);
            break;
          case "reading":
            assert.equal(facet.isWritable, false, `${model}: ${facet.id}`);
            break;
          case "button":
            assert.ok(facet.isWritable, `${model}: ${facet.id}`);
            assert.ok(facet.actionId !== undefined && facet.propertyId === undefined, `${model}: ${facet.id}`);
            break;
        }
        if (facet.propertyId !== undefined) {
          assert.equal(facet.id, `${facet.serviceId}.${facet.propertyId}`, `${model}: ${facet.id}`);
          assert.equal(facet.actionId, undefined, `${model}: ${facet.id}`);
        }
        if (facet.actionId !== undefined) {
          assert.equal(facet.id, `${facet.serviceId}.a${facet.actionId}`, `${model}: ${facet.id}`);
          assert.equal(facet.propertyId, undefined, `${model}: ${facet.id}`);
        }
        assert.ok(facet.propertyId !== undefined || facet.actionId !== undefined, `${model}: ${facet.id}`);
      }
    }
  });

  it("matches the shared coverage golden", () => {
    const measured: Record<string, CoverageEntry> = {};
    for (const [model, spec] of coverageSpecs()) {
      const facets = buildMiotFacets(spec, DEVICE_PROFILES, model);
      measured[model] = {
        ids: facets.map((facet) => facet.id),
        highValue: facets.filter((facet) => facet.highValue).map((facet) => facet.id),
      };
    }
    assert.deepEqual(Object.keys(measured).sort(), Object.keys(golden.models).sort());
    for (const model of Object.keys(golden.models).sort()) {
      assert.deepEqual(measured[model], golden.models[model], model);
    }
  });

  it("ships the same deviceProfiles.json as macOS", () => {
    const windows = readFileSync(resolve(process.cwd(), "src/core/miCloud/deviceProfiles.json"));
    const macos = readFileSync(resolve(fixtures, "..", "..", "Sources/MijiaCore/Resources/deviceProfiles.json"));
    assert.ok(windows.equals(macos));
  });

  it("synthesizes parameterized pet-food-out FeedAction with portions, fedToday, deduplication, and write-lock exemption (#7)", () => {
    const feederSpec = parseSpec({
      type: "urn:miot-spec-v2:device:pet-feeder:0000A06C:mmgg-feeder:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:pet-feeder:00007847:mmgg-feeder:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:feeding-measure:00000080:mmgg-feeder:1",
              format: "uint8",
              access: ["write"],
              "value-range": [1, 12, 1],
            },
            {
              iid: 6,
              type: "urn:miot-spec-v2:property:mode:00000008:mmgg-feeder:1",
              format: "uint8",
              access: ["read", "write"],
              "value-list": [
                { value: 0, description: "Normal" },
                { value: 1, description: "Smart" },
              ],
            },
          ],
          actions: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:action:pet-food-out:0000282B:mmgg-feeder:1",
              description: "Pet Food Out",
              in: [1],
            },
            {
              iid: 2,
              type: "urn:miot-spec-v2:action:pet-food-out:0000282B:mmgg-feeder:1",
              description: "Duplicate Feed",
              in: [1],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:action:set-level:00002800:mmgg-feeder:1",
              description: "Non-feeding parameterized action",
              in: [1],
            },
          ],
        },
        {
          iid: 5,
          type: "urn:miot-spec-v2:service:device-custom:00007800:mmgg-feeder:1",
          properties: [
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:today-feeded-num:00000001:mmgg-feeder:1",
              format: "uint8",
              access: ["read"],
              "value-range": [0, 50, 1],
            },
          ],
        },
      ],
    });

    const controls = facetControls(
      feederSpec,
      "did_feeder",
      new Map<string, unknown>([
        ["did_feeder.2.6", 0],
        ["did_feeder.5.2", 3],
      ]),
      null,
      new Set(),
      "mmgg.feeder.inland",
      DEVICE_PROFILES,
    );

    const buttons = controls.filter((c) => c.kind === "button");
    assert.equal(buttons.length, 1, "keeps only the first matching pet-food-out action and drops other parameterized actions");
    const feed = buttons[0]!;
    assert.equal(feed.id, "2.a1");
    assert.equal(feed.isConfirmedWrite, true);
    assert.equal(feed.writesByDefault, false);
    assert.equal(feed.portionArgumentIndex, 0);
    assert.equal(feed.fedToday, "3");
    assert.deepEqual(portionOptionsForControl(feed), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    assert.equal(isAdvancedWriteLocked(feed, false), false, "FeedAction is exempt from allowAdvancedFacetWrites");

    // Bounds check: wide ranges truncate at MAXIMUM_PORTION_OPTIONS (64), and unsafe floats return [].
    const wideFeed = {
      ...feed,
      arguments: [
        {
          propertyId: 1,
          name: "feeding-measure",
          format: "uint16",
          range: { min: 1, max: MAXIMUM_PORTION_OPTIONS + 10, step: 1 },
        },
      ],
    };
    assert.equal(portionOptionsForControl(wideFeed).length, MAXIMUM_PORTION_OPTIONS);
    const overflowFeed = {
      ...feed,
      arguments: [
        {
          propertyId: 1,
          name: "feeding-measure",
          format: "float",
          range: { min: 1, max: 1e20, step: 1 },
        },
      ],
    };
    assert.deepEqual(portionOptionsForControl(overflowFeed), []);
  });

  it("matches lockedControlIdForAlert and showsAdvancedViewOnlyCopy across languages", () => {
    const status = {
      id: "2.4",
      kind: "reading" as const,
      serviceName: "fish-tank",
      name: "water-pump-status",
      title: null,
      value: 4,
      unit: null,
      scale: null,
      range: null,
      options: [{ value: 4, label: "Blocked" }],
      isWritable: false,
      writesByDefault: false,
      isHighValue: false,
      target: null,
    };
    const pump = {
      id: "2.2",
      kind: "toggle" as const,
      serviceName: "fish-tank",
      name: "water-pump",
      title: null,
      value: true,
      unit: null,
      scale: null,
      range: null,
      options: [],
      isWritable: true,
      writesByDefault: false,
      isHighValue: false,
      target: { kind: "property" as const, entityId: "miot:tank:2", piid: 2 },
    };

    setLanguage("zh-Hans");
    try {
      const bakedAlert = facetAlertText(status, "Blocked");
      assert.equal(bakedAlert, "水泵状态：堵塞");
      assert.equal(lockedControlIdForAlert(bakedAlert, [status, pump], false), "2.2");
      assert.equal(lockedControlIdForAlert(bakedAlert, [status, pump], true), null);
      assert.equal(lockedControlIdForAlert(bakedAlert, [status, { ...pump, writesByDefault: true }], false), null);
      assert.equal(lockedControlIdForAlert(bakedAlert, [status, { ...pump, isConfirmedWrite: true }], false), null);
      assert.equal(showsAdvancedViewOnlyCopy([status, pump], false), true);
      assert.equal(showsAdvancedViewOnlyCopy([status, pump], true), false);

      setLanguage("en");
      assert.equal(lockedControlIdForAlert(bakedAlert, [status, pump], false), "2.2");
    } finally {
      setLanguage("zh-Hans");
    }
  });
});
