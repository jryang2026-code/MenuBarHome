import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { AppURLParser, BuiltInURLScene, URLDirectControl } from "../src/core/appUrlCommand.js";
import {
  DelayPhrase,
  IntentReply,
  IntentValidator,
  LocalIntentParser,
  UndoPhrase,
} from "../src/core/assistant.js";
import { spokenChineseNumber } from "../src/core/assistant/chineseIntentTables.js";
import { EnergyHistory, type EnergyStorageLike } from "../src/core/energyHistory.js";
import {
  HAHomeSnapshot,
  HAHomeSnapshotReadError,
  HomeAssistantSynthesizer,
  haServiceCall,
  homeAssistantCommand,
  homeAssistantIdentity,
  parseCachedHAHome,
} from "../src/core/homeAssistant.js";
import {
  MiotCommandMapper,
  MiotSynthesizer,
  miotShortName,
  parseMiotDeviceSpec,
  parseMiotInstanceIndex,
  propKeyString,
  type MiDeviceRecord,
  type MiRoom,
  type MiotDeviceSpec,
} from "../src/core/miCloudClient.js";
import type {
  DeviceCommand,
  DeviceIntent,
  HomeScene,
  IntentOperation,
  SmartDevice,
} from "../src/core/models.js";
import {
  ALL_SENSOR_METRICS,
  SensorHistoryStore,
  pointMetricRange,
  pointMetricValue,
  type StorageLike,
} from "../src/core/sensorHistory.js";

const UINT64_MASK = 0xffff_ffff_ffff_ffffn;

export class SeededFuzzGenerator {
  private state: bigint;

  constructor(seed: bigint) {
    this.state = seed & UINT64_MASK;
  }

  next(): bigint {
    this.state = (this.state + 0x9e37_79b9_7f4a_7c15n) & UINT64_MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & UINT64_MASK;
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & UINT64_MASK;
    return (z ^ (z >> 31n)) & UINT64_MASK;
  }

  int(min: number, max: number): number {
    const span = BigInt(max - min + 1);
    return min + Number(this.next() % span);
  }

  pick<T>(items: readonly T[]): T {
    return items[this.int(0, items.length - 1)]!;
  }

  bytes(count: number): Uint8Array {
    const out = new Uint8Array(count);
    for (let i = 0; i < count; i += 1) {
      out[i] = Number(this.next() & 0xffn);
    }
    return out;
  }
}

export const FuzzSupport = {
  baseSeed: 0x0000_0186_c0ff_ee01n,

  hex(data: Uint8Array | string): string {
    const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
    let out = "";
    for (let i = 0; i < bytes.length; i += 1) {
      out += bytes[i]!.toString(16).padStart(2, "0");
    }
    return out;
  },

  iterationSeed(base: bigint, iteration: number): bigint {
    return (base + ((BigInt(iteration) * 0x9e37_79b9n) & UINT64_MASK)) & UINT64_MASK;
  },

  formatContext(seed: bigint, iteration: number, input: Uint8Array | string): string {
    return `seed=${seed.toString(10)} iteration=${iteration} input=${this.hex(input)}`;
  },

  runIteration(
    seed: bigint,
    iteration: number,
    input: Uint8Array | string,
    body: () => void,
  ): void {
    try {
      body();
    } catch (error) {
      const ctx = this.formatContext(seed, iteration, input);
      const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      assert.fail(`${ctx} error=${detail}`);
    }
  },

  mutate(base: Uint8Array, rng: SeededFuzzGenerator): Uint8Array {
    let bytes = Array.from(base);
    switch (rng.int(0, 5)) {
      case 0: {
        const flips = rng.int(1, 8);
        for (let i = 0; i < flips && bytes.length > 0; i += 1) {
          const idx = rng.int(0, bytes.length - 1);
          bytes[idx] = (bytes[idx]! ^ (1 << rng.int(0, 7))) & 0xff;
        }
        break;
      }
      case 1: {
        bytes = bytes.slice(0, rng.int(0, bytes.length));
        break;
      }
      case 2: {
        const insertAt = rng.int(0, bytes.length);
        const extra = Array.from(rng.bytes(rng.int(1, 16)));
        bytes.splice(insertAt, 0, ...extra);
        break;
      }
      case 3: {
        if (bytes.length > 0) {
          const start = rng.int(0, bytes.length - 1);
          const count = rng.int(1, bytes.length - start);
          bytes.splice(start, count);
        }
        break;
      }
      case 4: {
        if (bytes.length > 0) {
          const start = rng.int(0, bytes.length - 1);
          const count = rng.int(1, bytes.length - start);
          const replacement = Array.from(rng.bytes(rng.int(0, 16)));
          bytes.splice(start, count, ...replacement);
        }
        break;
      }
      default: {
        bytes.push(...Array.from(rng.bytes(rng.int(0, 32))));
        break;
      }
    }
    return Uint8Array.from(bytes);
  },
} as const;

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");
const MIOT_SPEC_LIGHT_BYTES = new Uint8Array(
  readFileSync(path.join(REPO_ROOT, "Tests/Fixtures/contracts/miot_spec_light.json")),
);

const HOSTILE_NUMBERS: readonly number[] = [
  0,
  -0,
  1,
  -1,
  42,
  100,
  255,
  2700,
  6500,
  -2147483648,
  2147483647,
  Number.MIN_SAFE_INTEGER,
  Number.MAX_SAFE_INTEGER,
  Number.MIN_SAFE_INTEGER - 1024,
  Number.MAX_SAFE_INTEGER + 1024,
  1e100,
  -1e100,
  1e308,
  -1e308,
  1e-308,
  Number.NaN,
  Number.POSITIVE_INFINITY,
  Number.NEGATIVE_INFINITY,
];

function assertNoNonFiniteNumbers(value: unknown, pathLabel = "root"): void {
  if (typeof value === "number") {
    assert.ok(Number.isFinite(value), `Non-finite number ${String(value)} at ${pathLabel}`);
    return;
  }
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i += 1) {
      assertNoNonFiniteNumbers(value[i], `${pathLabel}[${i}]`);
    }
    return;
  }
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    assertNoNonFiniteNumbers(v, `${pathLabel}.${k}`);
  }
}

class InMemoryStorage implements EnergyStorageLike, StorageLike {
  private readonly map = new Map<string, string>();
  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.map.set(key, value);
  }
  removeItem(key: string): void {
    this.map.delete(key);
  }
}

describe("D4 SeededFuzzGenerator determinism & reproducible failure context", () => {
  it("produces bit-identical SplitMix64 sequences and formats seed/iteration/hex on failure", () => {
    const rngA = new SeededFuzzGenerator(FuzzSupport.baseSeed);
    const rngB = new SeededFuzzGenerator(FuzzSupport.baseSeed);
    for (let i = 0; i < 32; i += 1) {
      assert.equal(rngA.next(), rngB.next());
    }
    assert.deepEqual(rngA.bytes(24), rngB.bytes(24));

    const iterSeed = FuzzSupport.iterationSeed(FuzzSupport.baseSeed, 7);
    assert.throws(
      () =>
        FuzzSupport.runIteration(iterSeed, 7, new Uint8Array([0xde, 0xad, 0xbe, 0xef]), () => {
          throw new Error("boom");
        }),
      new RegExp(`seed=${iterSeed.toString(10)} iteration=7 input=deadbeef error=Error: boom`),
    );
  });
});

describe("D4 Target 1 · MIoT Spec parsing, MiotSynthesizer & MiotCommandMapper fuzz", () => {
  const suiteSeed = FuzzSupport.baseSeed ^ 0x00_3107_5ec0n;

  function randomHostileSpecObject(rng: SeededFuzzGenerator): Record<string, unknown> {
    const deviceTypes = [
      "light",
      "air-conditioner",
      "fan",
      "air-purifier",
      "outlet",
      "switch",
      "curtain",
      "airer",
      "humidifier",
      "dehumidifier",
      "heater",
      "water-heater",
      "vacuum",
      "camera",
      "lock",
      "temperature-humidity-sensor",
      "speaker",
      "pet-feeder",
      "electronic-valve",
      "unknown-gadget",
    ];
    const propNames = [
      "on",
      "brightness",
      "color-temperature",
      "mode",
      "fan-level",
      "speed-level",
      "target-temperature",
      "temperature",
      "relative-humidity",
      "electric-power",
      "power-consumption",
      "motor-control",
      "current-position",
      "target-position",
      "status",
      "fault",
      "door-state",
      "battery-level",
    ];
    const formats = ["bool", "uint8", "uint16", "uint32", "int8", "int32", "float", "string", ""];
    const devShort = rng.pick(deviceTypes);
    const serviceCount = rng.int(0, 4);
    const services: unknown[] = [];

    for (let s = 0; s < serviceCount; s += 1) {
      const svcShort = s === 0 ? devShort : rng.pick([...deviceTypes, "environment", "power-consumption", "battery"]);
      const propCount = rng.int(0, 8);
      const properties: unknown[] = [];
      for (let p = 0; p < propCount; p += 1) {
        const pName = rng.pick(propNames);
        const propObj: Record<string, unknown> = {
          type: `urn:miot-spec-v2:property:${pName}:0000000D:contract:1`,
          format: rng.pick(formats),
          access: rng.int(0, 4) === 0 ? "bad-access" : ["read", ...(rng.int(0, 1) === 1 ? ["write"] : []), "notify"],
        };
        if (rng.int(0, 5) !== 0) {
          propObj.iid = rng.int(0, 4) === 0 ? rng.pick(HOSTILE_NUMBERS) : p + 1;
        }
        if (rng.int(0, 1) === 0) {
          const rangeKind = rng.int(0, 4);
          if (rangeKind === 0) {
            propObj["value-range"] = [100, 1, rng.pick([1, 0, -5, 1e-308])];
          } else if (rangeKind === 1) {
            propObj["value-range"] = [rng.pick(HOSTILE_NUMBERS), rng.pick(HOSTILE_NUMBERS), rng.pick(HOSTILE_NUMBERS)];
          } else if (rangeKind === 2) {
            propObj["value-range"] = [0, 100];
          } else if (rangeKind === 3) {
            propObj["value-range"] = [];
          } else {
            propObj["value-range"] = [rng.int(-20, 50), rng.int(10, 200), rng.pick([0.5, 1, 5, 10])];
          }
        }
        if (rng.int(0, 1) === 0) {
          const listLen = rng.int(0, 4);
          propObj["value-list"] = Array.from({ length: listLen }, (_, idx) => ({
            value: rng.int(0, 3) === 0 ? rng.pick(HOSTILE_NUMBERS) : idx,
            description: rng.pick(["Auto", "Sleep", "Open", "Close", "Pause", "Locked", "No Fault", `v${idx}`, ""]),
          }));
        }
        properties.push(propObj);
      }

      const actionCount = rng.int(0, 3);
      const actions = Array.from({ length: actionCount }, (_, aIdx) => ({
        ...(rng.int(0, 5) === 0 ? {} : { iid: rng.int(0, 4) === 0 ? rng.pick(HOSTILE_NUMBERS) : aIdx + 1 }),
        type: `urn:miot-spec-v2:action:${rng.pick(["toggle", "start-sweep", "stop-sweeping", "play-text", "pet-food-out"])}:00002801:contract:1`,
        in: Array.from({ length: rng.int(0, 3) }, () => rng.pick([1, 2, ...HOSTILE_NUMBERS])),
      }));

      services.push({
        ...(rng.int(0, 5) === 0 ? {} : { iid: rng.int(0, 4) === 0 ? rng.pick(HOSTILE_NUMBERS) : s + 2 }),
        type: `urn:miot-spec-v2:service:${svcShort}:00007802:contract:1`,
        properties,
        actions,
      });
    }

    return {
      type: `urn:miot-spec-v2:device:${devShort}:0000A001:contract:2`,
      description: "Fuzz Spec Device",
      services,
    };
  }

  it("mutated MIoT spec bytes & instance indices decode or return null without trapping (250 iterations)", () => {
    const decoder = new TextDecoder("utf-8", { fatal: false });
    for (let iteration = 0; iteration < 250; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed, iteration);
      const rng = new SeededFuzzGenerator(seed);
      const mutated = FuzzSupport.mutate(MIOT_SPEC_LIGHT_BYTES, rng);
      FuzzSupport.runIteration(seed, iteration, mutated, () => {
        const text = decoder.decode(mutated);
        let parsedJson: unknown = text;
        try {
          parsedJson = JSON.parse(text);
        } catch (err) {
          void err;
        }
        const spec = parseMiotDeviceSpec(parsedJson);
        const index = parseMiotInstanceIndex(parsedJson);
        assert.equal(typeof index, "object");
        if (spec) {
          assert.equal(typeof miotShortName(spec.type), "string");
          for (const svc of spec.services) {
            assert.ok(Number.isSafeInteger(svc.iid));
            for (const prop of svc.properties) {
              assert.ok(Number.isSafeInteger(prop.iid));
              if (prop.valueList) {
                for (const item of prop.valueList) {
                  assert.ok(Number.isSafeInteger(item.value));
                }
              }
            }
            for (const action of svc.actions) {
              assert.ok(Number.isSafeInteger(action.iid));
              for (const inPiid of action.in ?? []) {
                assert.ok(Number.isSafeInteger(inPiid));
              }
            }
          }
        }
      });
    }
  });

  it("structured hostile MIoT specs + MiotSynthesizer + MiotCommandMapper never emit NaN/Infinity (200 iterations)", () => {
    const rooms: readonly MiRoom[] = [
      { id: "room-1", name: "客厅", dids: ["did-fuzz-1"], homeId: "home-1", homeName: "测试家" },
    ];
    for (let iteration = 0; iteration < 200; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed + 1n, iteration);
      const rng = new SeededFuzzGenerator(seed);
      const rawSpec = randomHostileSpecObject(rng);
      const serialized = JSON.stringify(rawSpec, (_k, v) =>
        typeof v === "number" && !Number.isFinite(v) ? String(v) : v,
      );
      FuzzSupport.runIteration(seed, iteration, serialized, () => {
        for (const candidate of [rawSpec, JSON.parse(serialized) as unknown]) {
          const spec = parseMiotDeviceSpec(candidate);
          if (!spec) continue;
          const record: MiDeviceRecord = {
            did: "did-fuzz-1",
            name: "Fuzz Device",
            model: "fuzz.vendor.v1",
            isOnline: rng.int(0, 3) !== 0,
            specType: spec.type,
          };
          const reqKeys = MiotSynthesizer.requiredProps(record, spec);
          const values = new Map<string, unknown>();
          for (const key of reqKeys) {
            assert.ok(Number.isSafeInteger(key.siid) && Number.isSafeInteger(key.piid));
            const choice = rng.int(0, 4);
            const val =
              choice === 0
                ? rng.pick(HOSTILE_NUMBERS)
                : choice === 1
                  ? rng.int(0, 1) === 1
                  : choice === 2
                    ? rng.pick(["true", "false", "1e308", "NaN", "Infinity", "24.5", ""])
                    : null;
            values.set(propKeyString(key), val);
          }

          const home = MiotSynthesizer.synthesize([record], rooms, { [record.model]: spec }, values);
          assertNoNonFiniteNumbers(home);

          for (const dev of home.devices) {
            const candidateCommands: DeviceCommand[] = [];
            if (dev.kind.kind === "light") {
              candidateCommands.push(
                { kind: "setLightPower", entityId: dev.kind.entityId, isOn: true },
                { kind: "setLightBrightness", entityId: dev.kind.entityId, percent: rng.pick(HOSTILE_NUMBERS) },
                { kind: "setLightColorTemp", entityId: dev.kind.entityId, kelvin: rng.pick(HOSTILE_NUMBERS) },
              );
            } else if (dev.kind.kind === "climate") {
              candidateCommands.push(
                { kind: "setClimateTemperature", entityId: dev.kind.entityId, temperature: rng.pick(HOSTILE_NUMBERS) },
              );
            } else if (dev.kind.kind === "fan") {
              candidateCommands.push(
                { kind: "setFanPercentage", entityId: dev.kind.entityId, percent: rng.pick(HOSTILE_NUMBERS) },
              );
            } else if (dev.kind.kind === "plug") {
              candidateCommands.push({ kind: "setSwitch", entityId: dev.kind.switchEntityId, isOn: false });
            } else if (dev.kind.kind === "cover") {
              candidateCommands.push({
                kind: "setNumberValue",
                entityId: dev.kind.entityId,
                value: rng.pick(HOSTILE_NUMBERS),
              });
            }
            for (const facet of home.deviceFacets?.[dev.id] ?? []) {
              const target = facet.target;
              if (facet.isWritable && target !== null && target.kind === "property") {
                candidateCommands.push({
                  kind: "setMiotProperty",
                  entityId: target.entityId,
                  piid: target.piid,
                  value: rng.pick(HOSTILE_NUMBERS),
                });
              }
            }

            for (const cmd of candidateCommands) {
              try {
                const mapped = MiotCommandMapper.map(cmd, spec);
                assertNoNonFiniteNumbers(mapped);
              } catch (err) {
                assert.ok(err instanceof Error);
              }
            }
          }
        }
      });
    }
  });

  it("pins minimal regressions for out-of-range value-list, inverted value-range, tiny step & NaN prop values", () => {
    for (const bad of [1e308, -1e308, 1e100, Number.NaN, Number.POSITIVE_INFINITY]) {
      const spec = parseMiotDeviceSpec({
        type: "urn:miot-spec-v2:device:light:0000A001:contract:1",
        services: [
          {
            iid: 2,
            type: "urn:miot-spec-v2:service:light:00007802:contract:1",
            properties: [
              {
                iid: 1,
                type: "urn:miot-spec-v2:property:mode:00000008:contract:1",
                format: "uint8",
                access: ["read", "write"],
                "value-list": [{ value: bad, description: "Bad" }],
              },
            ],
          },
        ],
      });
      assert.equal(spec?.services[0]?.properties[0]?.valueList, undefined);
    }

    const truncatedSpec = parseMiotDeviceSpec({
      type: "urn:miot-spec-v2:device:light:0000A001:contract:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:contract:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:mode:00000008:contract:1",
              format: "uint8",
              access: ["read", "write"],
              "value-list": [{ value: 2.9, description: "Truncated" }],
            },
          ],
        },
      ],
    });
    assert.deepEqual(truncatedSpec?.services[0]?.properties[0]?.valueList, [
      { value: 2, description: "Truncated" },
    ]);

    const invertedSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:contract:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:contract:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:on:00000006:contract:1",
              format: "bool",
              access: ["read", "write"],
            },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:brightness:0000000D:contract:1",
              format: "float",
              access: ["read", "write"],
              valueRange: [100, 1, 1e-308],
            },
          ],
          actions: [],
        },
      ],
    };
    for (const pct of [50, Number.NaN, Number.POSITIVE_INFINITY, -0, 1e308]) {
      const write = MiotCommandMapper.map(
        { kind: "setLightBrightness", entityId: "miot:did-1:2", percent: pct },
        invertedSpec,
      );
      assertNoNonFiniteNumbers(write);
    }

    const record: MiDeviceRecord = {
      did: "did-1",
      name: "Ceiling",
      model: "contract.light",
      isOnline: true,
      specType: invertedSpec.type,
    };
    const nanHome = MiotSynthesizer.synthesize(
      [record],
      [],
      { "contract.light": invertedSpec },
      new Map<string, unknown>([
        ["did-1.2.1", true],
        ["did-1.2.2", Number.NaN],
      ]),
    );
    assertNoNonFiniteNumbers(nanHome);

    const outletSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:outlet:0000A002:contract:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:outlet:00007802:contract:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:contract:1", format: "bool", access: ["read", "write"] },
            { iid: 2, type: "urn:miot-spec-v2:property:power-consumption:0000000D:contract:1", format: "float", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
    const hugeEnergyHome = MiotSynthesizer.synthesize(
      [{ did: "did-plug", name: "Plug", model: "contract.plug", isOnline: true, specType: outletSpec.type }],
      [],
      { "contract.plug": outletSpec },
      new Map<string, unknown>([
        ["did-plug.2.1", true],
        ["did-plug.2.2", 1e308],
      ]),
    );
    assertNoNonFiniteNumbers(hugeEnergyHome);
    assert.equal(hugeEnergyHome.devices[0]?.kind.kind, "plug");
    if (hugeEnergyHome.devices[0]?.kind.kind === "plug") {
      assert.equal(hugeEnergyHome.devices[0].kind.energyKwh, undefined);
    }
  });
});

describe("D4 Target 2 · Home Assistant Snapshot, WebSocket projection & Entity Registry fuzz", () => {
  const suiteSeed = FuzzSupport.baseSeed ^ 0x00_4a5_0000n;
  const wsKeys = [
    "type",
    "id",
    "success",
    "result",
    "error",
    "event",
    "event_type",
    "data",
    "new_state",
    "old_state",
    "entity_id",
    "state",
    "attributes",
    "friendly_name",
    "device_class",
    "supported_features",
  ] as const;
  const wsStrings = [
    "result",
    "event",
    "state_changed",
    "auth_required",
    "auth_ok",
    "light.ceiling",
    "climate.ac",
    "cover.curtain",
    "sensor.temperature",
    "scene.movie",
    "on",
    "off",
    "unavailable",
    "unknown",
    "temperature",
    "humidity",
    "battery",
    "1e308",
    "inf",
    "nan",
    "",
  ] as const;

  function randomWsValue(rng: SeededFuzzGenerator, depth: number): unknown {
    const maxChoice = depth >= 3 ? 3 : 6;
    switch (rng.int(0, maxChoice)) {
      case 0:
        return null;
      case 1:
        return rng.int(0, 1) === 1;
      case 2:
        return rng.pick(HOSTILE_NUMBERS);
      case 3:
        return rng.pick(wsStrings);
      case 4:
        return Array.from({ length: rng.int(0, 3) }, () => randomWsValue(rng, depth + 1));
      default: {
        const obj: Record<string, unknown> = {};
        const count = rng.int(0, 4);
        for (let i = 0; i < count; i += 1) {
          obj[rng.pick(wsKeys)] = randomWsValue(rng, depth + 1);
        }
        return obj;
      }
    }
  }

  it("random HA WebSocket frames & hostile snapshots never leak hidden/disabled entities or emit NaN/Infinity (300 iterations)", () => {
    for (let iteration = 0; iteration < 300; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed, iteration);
      const rng = new SeededFuzzGenerator(seed);

      const disabledReasons: readonly (string | null)[] = [null, "user", "integration", "config_entry"];
      const hiddenReasons: readonly (string | null)[] = [null, "user", "integration"];
      const devDisabled = rng.pick(disabledReasons);
      const entDisabled = rng.pick(disabledReasons);
      const entHidden = rng.pick(hiddenReasons);
      const sceneDisabled = rng.pick(disabledReasons);
      const sceneHidden = rng.pick(hiddenReasons);

      const snapshotPayload = {
        areas: [{ area_id: "area-1", name: "书房" }],
        devices: [
          {
            id: "dev-1",
            area_id: "area-1",
            name: "台灯",
            model: rng.pick(["yeelink.light.lamp", "xiaomi.clock.v1", "lumi.lock.v1", "zhimi.fan.v3"]),
            disabled_by: devDisabled,
          },
        ],
        entities: [
          {
            entity_id: "light.desk",
            device_id: "dev-1",
            disabled_by: entDisabled,
            hidden_by: entHidden,
          },
          {
            entity_id: "scene.night",
            disabled_by: sceneDisabled,
            hidden_by: sceneHidden,
          },
        ],
        states: [
          {
            entity_id: "light.desk",
            state: rng.pick(["on", "off", "unavailable", "unknown"]),
            attributes: {
              friendly_name: "Desk",
              brightness: rng.pick(HOSTILE_NUMBERS),
              color_temp_kelvin: rng.pick(HOSTILE_NUMBERS),
              min_color_temp_kelvin: rng.pick(HOSTILE_NUMBERS),
              max_color_temp_kelvin: rng.pick(HOSTILE_NUMBERS),
              supported_features: rng.pick([...HOSTILE_NUMBERS, "1e308", "nan", null]),
              supported_color_modes: rng.int(0, 2) === 0 ? "malformed" : ["brightness", "color_temp"],
              effect_list: rng.int(0, 2) === 0 ? [123, null, "Reading"] : ["Reading"],
            },
          },
          {
            entity_id: "climate.study",
            state: rng.pick(["cool", "off", "unavailable"]),
            attributes: {
              temperature: rng.pick(HOSTILE_NUMBERS),
              current_temperature: rng.pick(HOSTILE_NUMBERS),
              min_temp: rng.pick(HOSTILE_NUMBERS),
              max_temp: rng.pick(HOSTILE_NUMBERS),
              target_temp_step: rng.pick(HOSTILE_NUMBERS),
              supported_features: rng.pick(HOSTILE_NUMBERS),
            },
          },
          {
            entity_id: "scene.night",
            state: "scening",
            attributes: { friendly_name: "Night Scene" },
          },
        ],
      };

      const inputSummary = JSON.stringify(snapshotPayload, (_k, v) =>
        typeof v === "number" && !Number.isFinite(v) ? String(v) : v,
      );

      FuzzSupport.runIteration(seed, iteration, inputSummary, () => {
        const home = HomeAssistantSynthesizer.synthesize(snapshotPayload);
        assertNoNonFiniteNumbers(home);

        if (devDisabled !== null) {
          assert.ok(!home.devices.some((d) => d.id === "dev-1"));
        }
        if (devDisabled !== null || entDisabled !== null || entHidden !== null) {
          assert.ok(
            !home.devices.some(
              (d) => d.id === "light.desk" || (d.kind.kind === "light" && d.kind.entityId === "light.desk"),
            ),
          );
        }
        if (sceneDisabled !== null || sceneHidden !== null) {
          assert.ok(!home.scenes.some((s) => s.entityId === "scene.night"));
        }

        const cached = parseCachedHAHome({ identity: "http://192.0.2.10:8123|abc", home });
        assert.notEqual(cached, null);
        assertNoNonFiniteNumbers(cached);

        const ws = new HAHomeSnapshot();
        const frameCount = rng.int(1, 5);
        for (let f = 0; f < frameCount; f += 1) {
          const frame =
            rng.int(0, 1) === 0
              ? {
                  type: "result",
                  id: rng.pick([1, 2, 3, 4, 1001, 1e308, -1e308, "1e308", "inf", "nan"]),
                  success: rng.int(0, 3) !== 0,
                  result: randomWsValue(rng, 0),
                }
              : { type: "event", event: randomWsValue(rng, 0) };
          try {
            const projected = ws.receive(frame);
            if (projected) assertNoNonFiniteNumbers(projected);
          } catch (err) {
            assert.ok(err instanceof HAHomeSnapshotReadError);
          }
        }
      });
    }
  });

  it("holds back all 24 initial reply permutations until authoritative registries arrive & pins hostile numeric regressions", () => {
    const orders: number[][] = [];
    for (const a of [1, 2, 3, 4]) {
      for (const b of [1, 2, 3, 4]) {
        if (b === a) continue;
        for (const c of [1, 2, 3, 4]) {
          if (c === a || c === b) continue;
          for (const d of [1, 2, 3, 4]) {
            if (d === a || d === b || d === c) continue;
            orders.push([a, b, c, d]);
          }
        }
      }
    }
    assert.equal(orders.length, 24);

    const frameFor = (id: number) => {
      switch (id) {
        case 1:
          return { type: "result", id, success: true, result: [{ area_id: "office", name: "Office" }] };
        case 2:
          return { type: "result", id, success: true, result: [] };
        case 3:
          return {
            type: "result",
            id,
            success: true,
            result: [
              { entity_id: "light.visible", area_id: "office" },
              { entity_id: "light.hidden", hidden_by: "user" },
            ],
          };
        default:
          return {
            type: "result",
            id,
            success: true,
            result: [
              {
                entity_id: "light.visible",
                state: "on",
                attributes: { brightness: 1e308, supported_features: 1e308 },
              },
              { entity_id: "light.hidden", state: "on", attributes: {} },
            ],
          };
      }
    };

    for (const order of orders) {
      const projection = new HAHomeSnapshot();
      for (let i = 0; i < order.length; i += 1) {
        const res = projection.receive(frameFor(order[i]!));
        if (i < 3) {
          assert.equal(res, null);
        } else {
          assert.deepEqual(res?.devices.map((d) => d.id), ["light.visible"]);
          assert.equal(res?.devices[0]?.roomName, "Office");
          assert.equal(res?.devices[0]?.kind.kind, "light");
          if (res?.devices[0]?.kind.kind === "light") {
            assert.equal(res.devices[0].kind.brightnessPercent, null);
          }
        }
      }
    }

    for (const badVal of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
      assert.throws(() => haServiceCall({ kind: "setLightBrightness", entityId: "light.a", percent: badVal }));
      assert.throws(() => haServiceCall({ kind: "setClimateTemperature", entityId: "climate.a", temperature: badVal }));
      assert.throws(() => haServiceCall({ kind: "setNumberValue", entityId: "cover.a", value: badVal }));
      assert.throws(() => haServiceCall({ kind: "mediaSetVolume", entityId: "media_player.a", level: badVal }));
    }
    const zeroCall = haServiceCall({ kind: "setClimateTemperature", entityId: "climate.a", temperature: -0 });
    assert.equal(Object.is(zeroCall.data.temperature, -0), false);
    assert.equal(homeAssistantIdentity("http://192.0.2.1:8123\u0000evil", "tok"), null);
    assert.throws(() =>
      homeAssistantCommand({ kind: "setClimatePower", entityId: "climate.missing", isOn: true, resumeMode: "cool" }, []),
    );
  });
});

describe("D4 Target 3 · AppURLParser.parseEnvelope & URLDirectControl fuzz", () => {
  const suiteSeed = FuzzSupport.baseSeed ^ 0x00_aa11_cc22n;
  const baseUrls = [
    "menumijia://toggle?device=dev_1&token=0123456789abcdef&id=req_1",
    "menumijia://brightness?device=dev_light&percent=55",
    "menumijia://color-temp?device=dev_light&kelvin=4000",
    "menumijia://temperature?device=dev_ac&celsius=24.5",
    "menumijia://fan?device=dev_fan&percent=70",
    "menumijia://fan?device=dev_fan&preset=Auto",
    "menumijia://power?device=dev_plug&on=true",
    "menumijia://scene?name=quick%3AlightsOff",
    "menumijia://ask?text=%E6%89%93%E5%BC%80%E4%B9%A6%E6%88%BF%E7%81%AF",
    "menumijia://focus?device=dev_cam",
  ];

  it("mutated & adversarial menumijia:// links never throw and strictly bound numeric outputs (300 iterations)", () => {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder("utf-8", { fatal: false });
    const adversarialUrls = [
      "menumijia://brightness?device=d1&percent=-2147483648",
      `menumijia://brightness?device=d1&percent=${Number.MIN_SAFE_INTEGER}`,
      "menumijia://brightness?device=d1&percent=1e308",
      "menumijia://brightness?device=d1&percent=NaN",
      "menumijia://brightness?device=d1&percent=Infinity",
      "menumijia://temperature?device=d1&celsius=-0",
      "menumijia://temperature?device=d1&celsius=1e308",
      "menumijia://temperature?device=d1&celsius=999999999999999999999999999999",
      "menumijia://ask?text=%",
      "menumijia://ask?text=%G0",
      "menumijia://ask?text=%C0%AF",
      "menumijia://ask?text=%E0%80%AF",
      "menumijia://ask?text=%F0%80%80%AF",
      "menumijia://ask?text=%ED%A0%80",
      "menumijia://toggle?device=dev%00evil",
      "menumijia://toggle?device=dev%1fevil",
      "menumijia://toggle?device=dev\u0007evil",
      `menumijia://ask?text=${"a".repeat(501)}`,
      `menumijia://toggle?device=${"d".repeat(5000)}`,
    ];

    for (let i = 0; i < adversarialUrls.length; i += 1) {
      const raw = adversarialUrls[i]!;
      FuzzSupport.runIteration(suiteSeed, i, raw, () => {
        const env = AppURLParser.parseEnvelope(raw);
        if (raw.endsWith("celsius=-0")) {
          assert.equal(env?.command.kind, "temperature");
          if (env?.command.kind === "temperature") {
            assert.equal(Object.is(env.command.celsius, -0), false);
          }
        } else {
          assert.equal(env, null);
        }
      });
    }

    for (let iteration = 0; iteration < 300; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed + 1n, iteration);
      const rng = new SeededFuzzGenerator(seed);
      const base = encoder.encode(rng.pick(baseUrls));
      const mutated = FuzzSupport.mutate(base, rng);
      FuzzSupport.runIteration(seed, iteration, mutated, () => {
        const rawUrl = decoder.decode(mutated);
        const env = AppURLParser.parseEnvelope(rawUrl);
        const parsed = AppURLParser.parse(rawUrl);
        assert.deepEqual(parsed, env?.command ?? null);
        if (!env) return;
        assertNoNonFiniteNumbers(env);
        const cmd = env.command;
        if (cmd.kind === "brightness") {
          assert.ok(Number.isSafeInteger(cmd.percent) && cmd.percent >= 0 && cmd.percent <= 100);
          assert.equal(Object.is(cmd.percent, -0), false);
        } else if (cmd.kind === "colorTemp") {
          assert.ok(Number.isSafeInteger(cmd.kelvin) && cmd.kelvin >= 1000 && cmd.kelvin <= 20000);
        } else if (cmd.kind === "temperature") {
          assert.ok(Number.isFinite(cmd.celsius) && cmd.celsius >= -30 && cmd.celsius <= 100);
          assert.equal(Object.is(cmd.celsius, -0), false);
        } else if (cmd.kind === "fan") {
          assert.notEqual(cmd.percent !== null, cmd.preset !== null);
          if (cmd.percent !== null) {
            assert.ok(Number.isSafeInteger(cmd.percent) && cmd.percent >= 1 && cmd.percent <= 100);
          }
        } else if (cmd.kind === "scene") {
          void BuiltInURLScene.resolve(cmd.name);
        }
        void URLDirectControl.isValidBridgeToken(env.token, "0123456789abcdef");
      });
    }
  });
});

describe("D4 Target 4 · LocalIntentParser, EnergyHistory & SensorHistoryStore fuzz", () => {
  const suiteSeed = FuzzSupport.baseSeed ^ 0x00_7788_99aan;

  const sampleDevices: readonly SmartDevice[] = [
    {
      id: "dev-light",
      name: "书房吸顶灯",
      roomId: "r1",
      roomName: "书房",
      model: "yeelink.light.v1",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "light.study",
        isOn: true,
        brightnessPercent: 60,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: ["Reading", "Night"],
      },
    },
    {
      id: "dev-ac",
      name: "卧室空调",
      roomId: "r2",
      roomName: "卧室",
      model: "xiaomi.ac.v1",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "climate.bedroom",
        isOn: true,
        hvacMode: "cool",
        availableModes: ["cool", "heat", "dry", "off"],
        targetTemperature: 25,
        currentTemperature: 27,
        minTemp: 16,
        maxTemp: 30,
        step: 0.5,
        fanMode: "auto",
        availableFanModes: ["auto", "low", "high"],
      },
    },
    {
      id: "dev-plug",
      name: "桌面插座",
      roomId: "r1",
      roomName: "书房",
      model: "chuangmi.plug.v1",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "switch.desk",
        isOn: true,
        powerWatts: 120,
        energyKwh: 12.5,
        childLockEntityId: null,
        isChildLocked: false,
      },
    },
    {
      id: "dev-sensor",
      name: "客厅温湿度计",
      roomId: "r3",
      roomName: "客厅",
      model: "miaomiaoce.sensor_ht.t2",
      isOnline: true,
      kind: {
        kind: "sensor",
        temperature: 24.2,
        humidity: 52,
        battery: 88,
      },
    },
  ];
  const sampleScenes: readonly HomeScene[] = [
    { id: "scene-1", name: "回家模式", entityId: "scene.home" },
  ];

  it("LocalIntentParser, DelayPhrase, UndoPhrase, IntentValidator & IntentReply never trap or emit NaN/Infinity (250 iterations)", () => {
    const tokens = [
      "把",
      "书房灯",
      "卧室空调",
      "全部灯",
      "打开",
      "关掉",
      "调到",
      "调高",
      "降低",
      "度",
      "%",
      "K",
      "过5分钟",
      "撤销",
      "turn on",
      "set bedroom ac to",
      "brightness",
      "in 10 minutes",
      "99999999999999999999999999999999999999999999999999",
      "-2147483648",
      "1e308",
      "NaN",
      "Infinity",
      "\u001f",
      "\u0000",
      "([a-z]+)*$",
      "回家模式",
    ];

    for (let iteration = 0; iteration < 250; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed, iteration);
      const rng = new SeededFuzzGenerator(seed);
      const wordCount = rng.int(1, 8);
      const utterance = Array.from({ length: wordCount }, () => rng.pick(tokens)).join(
        rng.int(0, 1) === 0 ? "" : " ",
      );

      FuzzSupport.runIteration(seed, iteration, utterance, () => {
        void UndoPhrase.isUndo(utterance);
        void DelayPhrase.isCancel(utterance);
        const delay = DelayPhrase.extract(utterance);
        if (delay) {
          assert.ok(Number.isSafeInteger(delay.seconds) && delay.seconds > 0 && delay.seconds <= 86400);
          void DelayPhrase.formatDelay(delay.seconds);
        }

        const plan = LocalIntentParser.parse(utterance, sampleDevices, sampleScenes);
        const enPlan = LocalIntentParser.parseEnglish(utterance, sampleDevices, sampleScenes);
        for (const p of [plan, enPlan]) {
          if (!p) continue;
          assertNoNonFiniteNumbers(p);
          const sanitized = IntentValidator.sanitize(p.intents, sampleDevices, sampleScenes);
          assertNoNonFiniteNumbers(sanitized);
          for (const intent of sanitized) {
            const dev = sampleDevices.find((d) => d.id === intent.targetId);
            if (dev) {
              const cmds = IntentValidator.commandsForIntent(intent, dev);
              assertNoNonFiniteNumbers(cmds);
            }
          }
          const reply = IntentReply.describe(sanitized, sampleDevices, sampleScenes);
          assert.ok(!reply.includes("NaN") && !reply.includes("Infinity"));
        }

        const randomOp: IntentOperation = rng.pick<IntentOperation>([
          { kind: "brightness", percent: rng.pick(HOSTILE_NUMBERS) },
          { kind: "brightnessStep", delta: rng.pick(HOSTILE_NUMBERS) },
          { kind: "colorTemperature", kelvin: rng.pick(HOSTILE_NUMBERS) },
          { kind: "targetTemperature", celsius: rng.pick(HOSTILE_NUMBERS) },
          { kind: "temperatureStep", delta: rng.pick(HOSTILE_NUMBERS) },
        ]);
        const randomIntents: DeviceIntent[] = sampleDevices.map((d) => ({
          targetId: d.id,
          operation: randomOp,
        }));
        const cleanIntents = IntentValidator.sanitize(randomIntents, sampleDevices, sampleScenes);
        assertNoNonFiniteNumbers(cleanIntents);
      });
    }

    assert.equal(spokenChineseNumber("9".repeat(310)), null);
    assert.equal(DelayPhrase.extract(`过${"9".repeat(310)}秒关灯`), null);
    const markerPlan = LocalIntentParser.parse("打开\u001f书房吸顶灯", sampleDevices, sampleScenes);
    assertNoNonFiniteNumbers(markerPlan);

    const hostileClimate: SmartDevice = {
      id: "ac-inverted",
      name: "怪异空调",
      roomId: "r1",
      roomName: "书房",
      model: "test.ac",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "climate.weird",
        isOn: true,
        hvacMode: "cool",
        availableModes: ["cool", "off"],
        targetTemperature: Number.NaN,
        currentTemperature: null,
        minTemp: 35,
        maxTemp: 16,
        step: 1e-308,
        fanMode: null,
        availableFanModes: [],
      },
    };
    const normTemp = IntentValidator.normalize({ kind: "temperatureStep", delta: 2 }, hostileClimate);
    assertNoNonFiniteNumbers(normTemp);
  });

  it("EnergyHistory & SensorHistoryStore survive corrupted storage, rollbacks, spikes & 1e308 timestamps (200 iterations)", () => {
    const baseNow = new Date("2026-11-10T12:00:00Z");

    for (let iteration = 0; iteration < 200; iteration += 1) {
      const seed = FuzzSupport.iterationSeed(suiteSeed + 1n, iteration);
      const rng = new SeededFuzzGenerator(seed);
      const storage = new InMemoryStorage();

      if (rng.int(0, 2) === 0) {
        storage.setItem(
          "menumijia.windows.energyHistory.v1.fuzz",
          rng.pick([
            "{broken-json",
            "null",
            JSON.stringify({
              recordingStartedAtMs: rng.pick(HOSTILE_NUMBERS),
              baselines: { "plug-1": rng.pick(HOSTILE_NUMBERS) },
              lastSampleAtMs: { "plug-1": rng.pick(HOSTILE_NUMBERS) },
              buckets: [{ dayKey: rng.pick(["2026-11-09", "2026-02-31", "NaN-NaN-NaN"]), perDevice: { "plug-1": rng.pick(HOSTILE_NUMBERS) } }],
              observedDays: ["2026-11-09", "bad-day", 123],
            }),
          ]),
        );
        storage.setItem(
          "menumijia.sensorHistory.v1.fuzz",
          rng.pick([
            "{broken",
            JSON.stringify({
              version: 1,
              hourlyByDevice: {
                "sensor-1": [
                  {
                    bucketStartMs: rng.pick(HOSTILE_NUMBERS),
                    metrics: {
                      temperature: {
                        sum: rng.pick(HOSTILE_NUMBERS),
                        count: rng.pick([0, -1, 2, 1e308]),
                        min: rng.pick(HOSTILE_NUMBERS),
                        max: rng.pick(HOSTILE_NUMBERS),
                      },
                    },
                  },
                ],
              },
              dailyByDevice: {},
              cloudSyncedDevices: [123, "sensor-1"],
            }),
          ]),
        );
      }

      const seedHex = seed.toString(16).padStart(16, "0");
      FuzzSupport.runIteration(seed, iteration, seedHex, () => {
        const energy = new EnergyHistory({ scope: "fuzz", storage });
        const sensorStore = new SensorHistoryStore({ connectionScope: "fuzz", storage });

        for (let step = 0; step < 3; step += 1) {
          const tsChoice = rng.int(0, 4);
          const sampleDate =
            tsChoice === 0
              ? new Date(baseNow.getTime() + step * 3_600_000)
              : new Date(rng.pick(HOSTILE_NUMBERS));

          const plugReading = rng.pick(HOSTILE_NUMBERS);
          const plugDevice: SmartDevice = {
            id: "plug-1",
            name: "测试插座",
            roomId: "r1",
            roomName: "客厅",
            model: "chuangmi.plug.v1",
            isOnline: rng.int(0, 4) !== 0,
            kind: {
              kind: "plug",
              switchEntityId: "switch.p1",
              isOn: true,
              powerWatts: rng.pick(HOSTILE_NUMBERS),
              energyKwh: plugReading,
              childLockEntityId: null,
              isChildLocked: false,
            },
          };
          const sensorDevice: SmartDevice = {
            id: "sensor-1",
            name: "测试传感器",
            roomId: "r1",
            roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: rng.int(0, 4) !== 0,
            kind: {
              kind: "sensor",
              temperature: rng.pick(HOSTILE_NUMBERS),
              humidity: rng.pick(HOSTILE_NUMBERS),
              battery: rng.pick(HOSTILE_NUMBERS),
              statusText: rng.pick(["350 lx", "PM2.5 1e308", "NaN lx", ""]),
            },
          };

          energy.record([plugDevice], sampleDate);
          energy.applyPriceInput(rng.pick(["", "0.58", "0,62", "-5", "NaN", "1e308", "abc"]));
          sensorStore.record([sensorDevice], { now: sampleDate });
          sensorStore.mergeCloudSamples(
            "sensor-1",
            rng.pick(["24h", "7d"] as const),
            [
              {
                timestamp: rng.int(0, 1) === 0 ? sampleDate : rng.pick(HOSTILE_NUMBERS),
                temperature: rng.pick(HOSTILE_NUMBERS),
                minTemperature: rng.pick(HOSTILE_NUMBERS),
                maxTemperature: rng.pick(HOSTILE_NUMBERS),
                humidity: rng.pick(HOSTILE_NUMBERS),
                pm25: rng.pick(HOSTILE_NUMBERS),
                illuminance: rng.pick(HOSTILE_NUMBERS),
              },
            ],
            sampleDate,
          );
        }

        const queryNow = rng.int(0, 3) === 0 ? new Date(Number.NaN) : baseNow;
        const daily = energy.dailyTotals(rng.pick([1, 7, 31, -5, Number.NaN, 1e308]), queryNow);
        for (const row of daily) {
          assert.ok(Number.isFinite(row.kwh) && row.kwh >= 0);
          assert.ok(!row.dayKey.includes("NaN"));
          assert.ok(Number.isFinite(row.day.getTime()));
        }
        const top = energy.topDevices(7, rng.pick([6, 0, -1, Number.NaN]), [], queryNow);
        assertNoNonFiniteNumbers(top);
        const todayPlug = energy.todayKwh("plug-1", queryNow);
        if (todayPlug !== null) assert.ok(Number.isFinite(todayPlug) && todayPlug >= 0);
        const cost = energy.totalCost(7, queryNow);
        if (cost !== null) assert.ok(Number.isFinite(cost) && cost >= 0);

        for (const win of ["24h", "7d"] as const) {
          const pts = sensorStore.points("sensor-1", win, queryNow);
          assertNoNonFiniteNumbers(pts);
          for (const metric of ALL_SENSOR_METRICS) {
            for (const pt of pts) {
              const v = pointMetricValue(pt, metric);
              if (v !== null) assert.ok(Number.isFinite(v));
              const r = pointMetricRange(pt, metric);
              if (r !== null) assert.ok(Number.isFinite(r.min) && Number.isFinite(r.max) && r.min <= r.max);
            }
            const sum = sensorStore.summary("sensor-1", win, metric, queryNow);
            assertNoNonFiniteNumbers(sum);
          }
        }
      });
    }
  });
});
