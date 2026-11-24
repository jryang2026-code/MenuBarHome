import assert from "node:assert/strict";
import { it } from "node:test";
import { DualSourceCoordinator, type DualSourceInputSnapshot } from "../src/core/dualSourceProvider.js";
import { MiCloudError } from "../src/core/miCloudClient.js";

function snapshot(id: string, entityId: string): DualSourceInputSnapshot {
  return {
    home: {
      rooms: [], environmentReadings: [], scenes: [],
      devices: [{
        id, name: "Lamp", roomId: "room", roomName: "Room", model: "lamp", isOnline: true,
        kind: {
          kind: "light", entityId, isOn: false, brightnessPercent: 70,
          colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, currentEffect: null, availableEffects: [],
        },
      }],
    },
    identities: {
      [id]: {
        dids: ["12345678"], macAddresses: [], uniqueIds: [], model: "lamp",
        name: "Lamp", roomName: "Room", kindTag: "light",
      },
    },
  };
}

const ha = snapshot("ha-lamp", "light.lamp");
const mi = snapshot("mi-lamp", "miot:12345678:2");
const offline = async () => { throw new Error("Network unavailable"); };

it("keeps the pinned source through a roam and expires at 15 seconds of awake time", async () => {
  let awake = 1_000;
  const coordinator = new DualSourceCoordinator(null, { awakeTimeMs: () => awake });
  const refresh = (fetchHA: () => Promise<DualSourceInputSnapshot | null>) =>
    coordinator.refreshParallel({ fetchHA, fetchMi: async () => mi });

  const initial = await refresh(async () => ha);
  const id = initial.merged.home.devices[0]!.id;
  coordinator.pinStorage.pin(id, "homeAssistant");
  const dropped = await refresh(offline);
  assert.equal(dropped.sourceStatuses.homeAssistant.kind, "disconnected");
  assert.equal(dropped.merged.routes[id]?.backend, "homeAssistant");
  awake += 14_999;
  assert.equal((await refresh(offline)).merged.routes[id]?.backend, "homeAssistant");
  awake += 1;
  assert.equal((await refresh(offline)).merged.routes[id]?.backend, "xiaomiCloud");
  assert.equal((await refresh(async () => ha)).merged.routes[id]?.backend, "homeAssistant");
});

it("honors a manual disable or expired credentials immediately", async () => {
  let awake = 1_000;
  const coordinator = new DualSourceCoordinator(null, { awakeTimeMs: () => awake });
  const connect = () => coordinator.refreshParallel({ fetchHA: async () => ha, fetchMi: async () => mi });
  const id = (await connect()).merged.home.devices[0]!.id;
  coordinator.pinStorage.pin(id, "xiaomiCloud");
  const dropped = await coordinator.refreshParallel({ fetchHA: async () => ha, fetchMi: offline });
  assert.equal(dropped.merged.routes[id]?.backend, "xiaomiCloud");

  awake += 1;
  const expired = await coordinator.refreshParallel({
    fetchHA: async () => ha,
    fetchMi: async () => { throw new MiCloudError("sessionExpired", "Session expired"); },
  });
  assert.equal(expired.merged.routes[id]?.backend, "homeAssistant");

  await connect();
  assert.equal(coordinator.removeHomeAssistant()?.activeBackends.has("homeAssistant"), false);
  const disabled = await coordinator.refreshParallel({ fetchHA: async () => ha, fetchMi: async () => null });
  assert.equal(disabled.merged.routes[id]?.backend, "homeAssistant");
});
