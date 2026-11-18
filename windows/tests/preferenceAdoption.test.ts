import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  DeviceDeduplicator,
  extractHADeviceIdentities,
  extractMiDeviceIdentities,
} from "../src/core/dualSourceProvider.js";
import type { SmartDevice, SynthesizedHome } from "../src/core/models.js";
import { adoptPairedDevicePreferences, emptyLayoutPrefs } from "../src/ui/panelPrefs.js";

const LIGHT_MODEL = "yeelink.light.ceiling20";

function makeLightDevice(overrides: {
  id: string;
  name: string;
  roomId: string;
  roomName: string;
  entityId: string;
  isOnline?: boolean;
}): SmartDevice {
  return {
    id: overrides.id,
    name: overrides.name,
    roomId: overrides.roomId,
    roomName: overrides.roomName,
    model: LIGHT_MODEL,
    isOnline: overrides.isOnline ?? true,
    kind: {
      kind: "light",
      entityId: overrides.entityId,
      isOn: true,
      brightnessPercent: 75,
      colorTempKelvin: 4000,
      minKelvin: 2700,
      maxKelvin: 6500,
      availableEffects: [],
      currentEffect: null,
    },
  };
}

function buildPairableSnapshots() {
  const haLamp = makeLightDevice({ id: "ha-lamp-1", name: "主灯", roomId: "area-1", roomName: "客厅", entityId: "light.main_lamp" });
  const miLamp = makeLightDevice({ id: "11223344", name: "主灯", roomId: "mi-1", roomName: "客厅", entityId: "miot:11223344:2:1" });
  const haSnap: SynthesizedHome = { devices: [haLamp], rooms: [], environmentReadings: [], scenes: [] };
  const miSnap: SynthesizedHome = { devices: [miLamp], rooms: [], environmentReadings: [], scenes: [] };
  return {
    ha: {
      home: haSnap,
      identities: extractHADeviceIdentities(
        {
          areas: [{ area_id: "area-1", name: "客厅" }],
          devices: [{ id: "ha-lamp-1", area_id: "area-1", name: "主灯", model: LIGHT_MODEL, identifiers: [["xiaomi_home", "11223344"]], connections: [] }],
          entities: [],
          states: [],
        },
        haSnap,
      ),
    },
    mi: {
      home: miSnap,
      identities: extractMiDeviceIdentities(
        [{ did: "11223344", name: "主灯", model: LIGHT_MODEL, specType: null, isOnline: true }],
        miSnap,
      ),
    },
  };
}

describe("cross-source preference adoption (#24)", () => {
  it("reports the orphaned Mi id when both sides hold preference history", () => {
    const snaps = buildPairableSnapshots();
    const res = DeviceDeduplicator.merge({
      homeAssistant: snaps.ha,
      xiaomiCloud: snaps.mi,
      knownPreferenceIds: new Set(["ha-lamp-1", "11223344"]),
    });
    assert.equal(res.home.devices.length, 1);
    assert.equal(res.home.devices[0]!.id, "ha-lamp-1");
    assert.deepEqual(res.preferenceAdoptions, { "ha-lamp-1": "11223344" });
  });

  it("adopts nothing when only one side holds history", () => {
    const snaps = buildPairableSnapshots();

    const miOnly = DeviceDeduplicator.merge({
      homeAssistant: snaps.ha,
      xiaomiCloud: snaps.mi,
      knownPreferenceIds: new Set(["11223344"]),
    });
    assert.equal(miOnly.home.devices[0]!.id, "11223344");
    assert.deepEqual(miOnly.preferenceAdoptions, {});

    const haOnly = DeviceDeduplicator.merge({
      homeAssistant: snaps.ha,
      xiaomiCloud: snaps.mi,
      knownPreferenceIds: new Set(["ha-lamp-1"]),
    });
    assert.equal(haOnly.home.devices[0]!.id, "ha-lamp-1");
    assert.deepEqual(haOnly.preferenceAdoptions, {});
  });

  it("reports the HA id when the canonical registry already picked the Mi id", () => {
    const snaps = buildPairableSnapshots();
    const first = DeviceDeduplicator.merge({
      homeAssistant: snaps.ha,
      xiaomiCloud: snaps.mi,
      knownPreferenceIds: new Set(["11223344"]),
    });
    const second = DeviceDeduplicator.merge({
      homeAssistant: snaps.ha,
      xiaomiCloud: snaps.mi,
      canonical: first.canonical,
      knownPreferenceIds: new Set(["ha-lamp-1", "11223344"]),
    });
    assert.equal(second.home.devices[0]!.id, "11223344");
    assert.deepEqual(second.preferenceAdoptions, { "11223344": "ha-lamp-1" });
  });

  it("merges hidden, pinned, order, alias and tile prefs without overwriting the winner (#24)", () => {
    const layout = emptyLayoutPrefs();
    layout.hiddenDeviceIds = ["111000111"];
    layout.pinnedDeviceIds = ["111000111"];
    layout.order = ["a", "111000111", "b"];
    layout.aliases = { "111000111": "门厅筒灯" };
    layout.tileSizes = { "客厅|111000111": "half", "111000111": "full" };

    const changed = adoptPairedDevicePreferences(layout, { "ha-light-a": "111000111" });
    assert.equal(changed, true);
    assert.deepEqual(layout.hiddenDeviceIds, ["111000111", "ha-light-a"]);
    assert.deepEqual(layout.pinnedDeviceIds, ["111000111", "ha-light-a"]);
    assert.deepEqual(layout.order, ["a", "111000111", "ha-light-a", "b"]);
    assert.equal(layout.aliases["ha-light-a"], "门厅筒灯");
    assert.equal(layout.tileSizes["客厅|ha-light-a"], "half");
    assert.equal(layout.tileSizes["ha-light-a"], "full");

    // The orphaned entries stay, so a return to single-source Mi still works.
    assert.equal(layout.aliases["111000111"], "门厅筒灯");

    // Idempotent: the same adoption again changes nothing.
    assert.equal(adoptPairedDevicePreferences(layout, { "ha-light-a": "111000111" }), false);
  });

  it("never overwrites an explicit value on the canonical side", () => {
    const layout = emptyLayoutPrefs();
    layout.hiddenDeviceIds = [];
    layout.aliases = { "ha-light-b": "客厅主灯", "222000222": "旧名字" };
    layout.tileSizes = { "客厅|ha-light-b": "hero", "客厅|222000222": "half" };

    const changed = adoptPairedDevicePreferences(layout, { "ha-light-b": "222000222" });
    assert.equal(changed, false);
    assert.equal(layout.aliases["ha-light-b"], "客厅主灯");
    assert.equal(layout.tileSizes["客厅|ha-light-b"], "hero");
    assert.deepEqual(layout.hiddenDeviceIds, []);
  });
});
