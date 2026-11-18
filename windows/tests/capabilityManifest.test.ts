import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import {
  ALL_CAPABILITY_IDS, CONNECTION_CAPABILITY_IDS, CONNECTION_TO_HOME_BACKEND, CapabilityManifestError,
  DEVICE_CATEGORY_IDS, DEVICE_CATEGORY_PRIMARY_KIND_TAG, HOME_BACKEND_TO_CONNECTION,
  connectionCapabilityForMode, deviceCategoryForDevice, loadSharedCapabilityManifest, parseCapabilityManifest,
} from "../src/core/capabilityManifest.js";
import type { SmartDevice } from "../src/core/models.js";

const loadRawJson = (rel: string): Record<string, unknown> =>
  JSON.parse(readFileSync(resolve(process.cwd(), "..", rel), "utf8")) as Record<string, unknown>;

describe("Shared capability manifest (P1a)", () => {
  it("loads Shared/capability-manifest.json and covers every docs/capabilities.json row", () => {
    const manifest = loadSharedCapabilityManifest();
    const docs = loadRawJson("docs/capabilities.json") as { rows: Array<{ id: string }> };
    const docRowIds = new Set(docs.rows.map((r) => r.id));

    assert.equal(manifest.schemaVersion, 1);
    assert.equal(manifest.entries.length, ALL_CAPABILITY_IDS.length);
    assert.deepEqual(manifest.entryFor("camera-live").dependsOn, ["camera"]);
    assert.equal(manifest.entryFor("xiaomi-cloud").defaultOnFreshInstall, false);
    assert.equal(manifest.entryFor("home-assistant").defaultOnFreshInstall, false);
    assert.equal(manifest.entryFor("voice-input").platforms.windows, "partial");
    assert.equal(manifest.entryFor("grokball").platforms.windows, "unsupported");
    assert.equal(manifest.entryFor("light").defaultOnFreshInstall, true);

    const covered = new Set<string>(manifest.hostCoreCapabilityMatrixIds);
    for (const entry of manifest.entries) {
      for (const rowId of entry.capabilityMatrix.rowIds) {
        assert.ok(docRowIds.has(rowId), `unknown docs row ${rowId}`);
        covered.add(rowId);
      }
    }
    assert.deepEqual([...covered].sort(), [...docRowIds].sort());
  });

  it("maps HomeBackend and SmartDevice kinds exhaustively including HA valves and humidifiers", () => {
    for (const id of CONNECTION_CAPABILITY_IDS) assert.equal(HOME_BACKEND_TO_CONNECTION[CONNECTION_TO_HOME_BACKEND[id]], id);
    assert.equal(connectionCapabilityForMode("demo"), null);
    for (const cat of DEVICE_CATEGORY_IDS) assert.ok(DEVICE_CATEGORY_PRIMARY_KIND_TAG[cat].length > 0);

    const valveAppliance: SmartDevice = {
      id: "valve.water_main", name: "总水阀", roomId: "kitchen", roomName: "厨房", model: "ha.valve", isOnline: true,
      kind: {
        kind: "appliance", entityId: "valve.water_main", isOn: false, powerPresent: true, powerWritable: true,
        currentMode: null, availableModes: [], modeWritable: false, targetTemperature: null, currentTemperature: null,
        minTemp: 0, maxTemp: 100, step: 1, temperatureWritable: false, statusText: null, faultText: null,
        remainingMinutes: null, startAction: null, pauseAction: null, stopAction: null,
        powerEntityId: "valve.water_main", modeEntityId: "valve.water_main", temperatureEntityId: "valve.water_main",
        light: null, fanLevel: null, currentHumidity: null, symbolName: null, roomReading: false, heats: false,
      },
    };
    assert.equal(deviceCategoryForDevice(valveAppliance), "valve");

    const humidifier: SmartDevice = {
      id: "humidifier.bedroom", name: "加湿器", roomId: "bedroom", roomName: "卧室", model: "ha.humidifier", isOnline: true,
      kind: {
        kind: "humidifier", entityId: "humidifier.bedroom", isOn: true, targetHumidity: 55, currentHumidity: 48,
        minHumidity: 30, maxHumidity: 80, step: 1, humidityWritable: true, currentMode: null, availableModes: [],
        modeWritable: false, powerWritable: true,
      },
    };
    assert.equal(deviceCategoryForDevice(humidifier), "fan");
  });

  it("rejects unknown IDs, duplicate IDs, cycles, missing entries, and forbidden fields", () => {
    const mutate = (edit: (caps: Array<Record<string, unknown>>) => void) => {
      const m = structuredClone(loadRawJson("Shared/capability-manifest.json"));
      edit(m.capabilities as Array<Record<string, unknown>>);
      return m;
    };
    const expectCode = (raw: unknown, code: string) =>
      assert.throws(() => parseCapabilityManifest(raw), (e: unknown) => e instanceof CapabilityManifestError && e.code === code);

    expectCode(mutate((c) => c.push({ ...c[0], id: "external-plugin" })), "unknown_capability_id");
    expectCode(mutate((c) => c.push(structuredClone(c[0]!))), "duplicate_capability_id");
    expectCode(mutate((c) => { c[2]!.dependsOn = ["ai-assistant"]; c[3]!.dependsOn = ["voice-input"]; }), "dependency_cycle");
    expectCode(mutate((c) => { c.pop(); }), "missing_capabilities");
    expectCode(mutate((c) => { for (const x of c) if (x.id === "camera") x.defaultOnFreshInstall = false; }), "invalid_default_dependency");
    expectCode(mutate((c) => { c[0]!.secretKey = "nope"; }), "unexpected_keys");
  });
});
