import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS,
  CANONICAL_DEVICE_REGISTRY_STORAGE_KEY,
  CanonicalDeviceRegistry,
  type NativeCanonicalRegistry,
} from "../src/core/canonicalDeviceRegistry.js";

import { DeviceDeduplicator, DualSourceCoordinator, makeDeviceSourceIdentity, type DualSourceInputSnapshot } from "../src/core/dualSourceProvider.js";
import type { SmartDevice } from "../src/core/models.js";

const DAY = 24 * 60 * 60 * 1000;

function haSnapshot(id: string, haScope = "ha:https://ha.example"): DualSourceInputSnapshot {
  const device: SmartDevice = {
    id,
    name: "Lamp",
    model: "lamp",
    roomId: "room",
    roomName: "Room",
    isOnline: true,
    kind: {
      kind: "light", entityId: "light.lamp", isOn: false, brightnessPercent: null,
      colorTempKelvin: null, minKelvin: 2200, maxKelvin: 6500, currentEffect: null, availableEffects: [],
    },
  };
  return {
    haScope,
    home: { devices: [device], rooms: [], environmentReadings: [], scenes: [] },
    identities: { [id]: makeDeviceSourceIdentity({ dids: ["lamp-unique"], uniqueIds: ["lamp-unique"], kindTag: "light" }) },
  };
}

class MemoryStorage implements Storage {
  private values = new Map<string, string>();
  get length(): number { return this.values.size; }
  clear(): void { this.values.clear(); }
  getItem(key: string): string | null { return this.values.get(key) ?? null; }
  key(index: number): string | null { return [...this.values.keys()][index] ?? null; }
  removeItem(key: string): void { this.values.delete(key); }
  setItem(key: string, value: string): void { this.values.set(key, value); }
}

describe("CanonicalDeviceRegistry tombstones", () => {
  it("restores within 30 days and purges after retention", () => {
    const registry = new CanonicalDeviceRegistry({ "did:lamp": "mi:lamp" });
    registry.reconcile(new Set(), 1_000);
    assert.equal(registry.canonicalId(["did:lamp"]), "mi:lamp");
    registry.purge(1_000 + 30 * 24 * 60 * 60 * 1000);
    assert.equal(registry.canonicalId(["did:lamp"]), null);
  });

  it("returns the original preference key for a matching HA device after a gap", () => {
    const now = 1_000;
    const preferences = { old: { alias: "Reading lamp", pinned: true, hidden: true } };
    const first = DeviceDeduplicator.merge({ homeAssistant: haSnapshot("old"), registryNowMs: now });
    const absent = DeviceDeduplicator.merge({ canonical: first.canonical, registryNowMs: now });
    const recover = (registryNowMs: number, haScope?: string) => DeviceDeduplicator.merge({
      homeAssistant: haSnapshot("new", haScope),
      canonical: absent.canonical,
      registryNowMs,
    }).home.devices[0]?.id;
    const restoredId = recover(now + DAY);
    assert.equal(restoredId, "old");
    assert.deepEqual(preferences[restoredId], preferences.old);
    const restored = DeviceDeduplicator.merge({
      homeAssistant: haSnapshot("new"), canonical: absent.canonical, registryNowMs: now + DAY,
    });
    const foreign = DeviceDeduplicator.merge({
      homeAssistant: haSnapshot("foreign", "ha:https://other.example"),
      canonical: restored.canonical,
      registryNowMs: now + DAY,
    });
    assert.equal(foreign.home.devices[0]?.id, "foreign");
    assert.equal(recover(now + 30 * DAY), "new");
  });

  it("loads the saved registry before committing a reconnect snapshot", async () => {
    const identity = DeviceDeduplicator.merge({ homeAssistant: haSnapshot("old") }).canonical;
    const tombstones = DeviceDeduplicator.merge({ canonical: identity }).canonical;
    let finishSave!: (value: Parameters<NativeCanonicalRegistry["save"]>[0]) => void;
    const saved = new Promise<Parameters<NativeCanonicalRegistry["save"]>[0]>((resolve) => {
      finishSave = resolve;
    });
    const coordinator = new DualSourceCoordinator(new MemoryStorage(), {
      nativeRegistry: {
        load: async () => ({ revision: 3, registry: tombstones.state() }),
        save: async (registry, revision) => {
          assert.equal(revision, 3);
          finishSave(registry);
          return true;
        },
      },
    });
    const outcome = await coordinator.refreshParallel({
      fetchHA: async () => haSnapshot("new"),
      fetchMi: async () => null,
    });
    assert.equal(outcome.merged.home.devices[0]?.id, "old");
    assert.equal((await saved).orphanedAt, undefined);
  });

  it("does not restore an explicitly forgotten device", () => {
    const registry = new CanonicalDeviceRegistry({ "did:lamp": "mi:lamp" });
    registry.forget("mi:lamp");
    registry.assign("mi:lamp", ["did:lamp"]);
    assert.equal(registry.canonicalId(["did:lamp"]), null);
  });

  it("loads the newest valid backup and bounds rolling copies", () => {
    const storage = new MemoryStorage();
    for (const value of ["one", "two", "three", "four"]) {
      new CanonicalDeviceRegistry({ "did:lamp": value }).save(storage);
    }
    assert.equal(storage.length, 3);
    storage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, '{"assignments":42}');
    assert.equal(CanonicalDeviceRegistry.load(storage).canonicalId(["did:lamp"]), "three");
    storage.setItem(CANONICAL_DEVICE_REGISTRY_BACKUP_KEYS[0], "broken");
    assert.equal(CanonicalDeviceRegistry.load(storage).canonicalId(["did:lamp"]), "two");
  });

  it("does not bring deleted mappings back through a backup", () => {
    const storage = new MemoryStorage();
    const registry = new CanonicalDeviceRegistry({ "did:lamp": "mi:lamp" });
    registry.save(storage);
    registry.forget("mi:lamp");
    registry.save(storage);
    storage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, "broken");
    assert.equal(CanonicalDeviceRegistry.load(storage).canonicalId(["did:lamp"]), null);
  });

  it("loads the legacy flat assignment format", () => {
    const storage = new MemoryStorage();
    storage.setItem(CANONICAL_DEVICE_REGISTRY_STORAGE_KEY, JSON.stringify({ "did:lamp": "mi:lamp" }));
    assert.equal(CanonicalDeviceRegistry.load(storage).canonicalId(["did:lamp"]), "mi:lamp");
  });
});
