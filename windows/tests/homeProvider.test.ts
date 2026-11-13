import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DemoHomeProvider,
  HomeAssistantProvider,
  MiCloudProvider,
  PowerReadBackError,
  type HomeProvider,
} from "../src/core/homeProvider.js";
import { parseMiotDeviceSpec, propKeyString } from "../src/core/miCloudClient.js";
import type { MiotActionCall, MiotPropKey, MiotPropWrite } from "../src/core/miCloudClient.js";
import type { MiotDeviceSpec } from "../src/core/miCloudClient.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";

// Each backend behind the one `HomeProvider.execute` call, without the app (ADR-0020).

function spec(raw: unknown): MiotDeviceSpec {
  const parsed = parseMiotDeviceSpec(raw);
  assert.ok(parsed, "the test spec parses");
  return parsed;
}

const plugSpec = spec({
  type: "urn:miot-spec-v2:device:outlet:0000A002:unit-plug:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:switch:0000780C:unit-plug:1",
      properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:unit-plug:1", format: "bool", access: ["read", "write"] },
      ],
    },
  ],
});

const vacuumSpec = spec({
  type: "urn:miot-spec-v2:device:vacuum:0000A006:unit-vac:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:vacuum:00007810:unit-vac:1",
      properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:status:00000007:unit-vac:1", format: "uint8", access: ["read"] },
      ],
      actions: [
        { iid: 1, type: "urn:miot-spec-v2:action:start-sweep:00002804:unit-vac:1", in: [] },
      ],
    },
  ],
});

function plug(): SmartDevice {
  return {
    id: "plug1", name: "插座", roomId: "study", roomName: "书房", model: "unit.plug.v1", isOnline: true,
    kind: { kind: "plug", switchEntityId: "miot:plug1:2", isOn: false, powerWatts: null, energyKwh: null },
  } as SmartDevice;
}

const turnOn: DeviceCommand = { kind: "setSwitch", entityId: "miot:plug1:2", isOn: true };

interface FakeCloud {
  readonly log: string[];
  readonly client: {
    setProps(writes: readonly MiotPropWrite[]): Promise<void>;
    getProps(keys: readonly MiotPropKey[]): Promise<Map<string, unknown>>;
    action(call: MiotActionCall): Promise<void>;
  };
}

/** A cloud that records the order of its requests and answers a read with what `read` returns. */
function fakeCloud(read: () => unknown = () => true): FakeCloud {
  const log: string[] = [];
  return {
    log,
    client: {
      async setProps(writes) {
        log.push(`setProps:${writes.map((write) => `${propKeyString(write)}=${String(write.value)}`).join(",")}`);
      },
      async getProps(keys) {
        log.push("getProps");
        const value = read();
        return new Map(keys.map((key) => [propKeyString(key), value]));
      },
      async action(call) {
        log.push(`action:${call.siid}.${call.aiid}`);
      },
    },
  };
}

function miProvider(cloud: FakeCloud, deviceSpec = plugSpec, devices: SmartDevice[] = [plug()]): MiCloudProvider {
  return new MiCloudProvider({
    client: cloud.client,
    specResolver: {
      async resolve() {
        cloud.log.push("resolveSpec");
        return deviceSpec;
      },
    },
    deviceForEntity: (entityId) =>
      devices.find((device) => device.kind.kind === "plug" && device.kind.switchEntityId === entityId) ??
      devices.find((device) => "entityId" in device.kind && device.kind.entityId === entityId),
  });
}

describe("DemoHomeProvider", () => {
  it("sends nothing and never asks the caller whether the source is still current", async () => {
    let asked = false;
    const provider: HomeProvider = new DemoHomeProvider();
    const result = await provider.execute(turnOn, { readBackPower: true, beforeSend: () => { asked = true; } });
    assert.equal(result, null);
    assert.equal(asked, false);
  });
});

describe("HomeAssistantProvider", () => {
  it("waits for the endpoint, then asks the caller, then sends", async () => {
    const log: string[] = [];
    let release: () => void = () => {};
    const ready = new Promise<void>((resolve) => {
      release = resolve;
    });
    const provider = new HomeAssistantProvider(
      { async execute(command) { log.push(`execute:${command.kind}`); } },
      ready.then(() => log.push("ready")),
    );
    const pending = provider.execute(turnOn, { beforeSend: () => log.push("beforeSend") });
    await Promise.resolve();
    assert.deepEqual(log, [], "nothing goes out while the endpoint is still being submitted");
    release();
    assert.equal(await pending, null);
    assert.deepEqual(log, ["ready", "beforeSend", "execute:setSwitch"]);
  });

  it("does not send when the caller refuses in beforeSend", async () => {
    let sent = false;
    const provider = new HomeAssistantProvider({ async execute() { sent = true; } });
    await assert.rejects(
      provider.execute(turnOn, { beforeSend: () => { throw new Error("Connection source changed"); } }),
      /Connection source changed/,
    );
    assert.equal(sent, false);
  });

  it("does not send when the endpoint submission failed", async () => {
    let sent = false;
    const provider = new HomeAssistantProvider(
      { async execute() { sent = true; } },
      Promise.reject(new Error("endpoint refused")),
    );
    await assert.rejects(provider.execute(turnOn), /endpoint refused/);
    assert.equal(sent, false);
  });
});

describe("MiCloudProvider", () => {
  it("resolves the spec before asking the caller, and asks before the first request", async () => {
    const cloud = fakeCloud();
    const result = await miProvider(cloud).execute(turnOn, { beforeSend: () => cloud.log.push("beforeSend") });
    assert.equal(result, null, "no read-back unless it was asked for");
    assert.deepEqual(cloud.log, ["resolveSpec", "beforeSend", "setProps:plug1.2.1=true"]);
  });

  it("sends no request when the caller refuses in beforeSend", async () => {
    const cloud = fakeCloud();
    await assert.rejects(
      miProvider(cloud).execute(turnOn, { beforeSend: () => { throw new Error("Connection source changed"); } }),
      /Connection source changed/,
    );
    assert.deepEqual(cloud.log, ["resolveSpec"]);
  });

  it("refuses a command no card owns before resolving anything", async () => {
    const cloud = fakeCloud();
    await assert.rejects(
      miProvider(cloud).execute({ kind: "setSwitch", entityId: "miot:stranger:2", isOn: true }),
      /无法找到指令对应的设备|device/i,
    );
    assert.deepEqual(cloud.log, []);
  });

  it("returns the power state read back after the write", async () => {
    for (const [raw, expected] of [[true, true], [false, false], [1, true], [0, false]] as const) {
      const cloud = fakeCloud(() => raw);
      assert.equal(await miProvider(cloud).execute(turnOn, { readBackPower: true }), expected);
      assert.deepEqual(cloud.log, ["resolveSpec", "setProps:plug1.2.1=true", "getProps"]);
    }
  });

  it("reports a failed read-back with the original error as its reason", async () => {
    const failure = new Error("HTTP 500");
    const cloud = fakeCloud(() => { throw failure; });
    await assert.rejects(miProvider(cloud).execute(turnOn, { readBackPower: true }), (error: unknown) => {
      assert.ok(error instanceof PowerReadBackError);
      assert.equal(error.reason, failure, "the caller rethrows the cloud's own error");
      return true;
    });
    assert.deepEqual(cloud.log, ["resolveSpec", "setProps:plug1.2.1=true", "getProps"], "the write still went out");
  });

  it("reports a read-back that is not a power reading", async () => {
    for (const raw of [undefined, null, "on", 2]) {
      const cloud = fakeCloud(() => raw);
      await assert.rejects(miProvider(cloud).execute(turnOn, { readBackPower: true }), (error: unknown) => {
        assert.ok(error instanceof PowerReadBackError);
        assert.ok(error.reason instanceof Error);
        return true;
      });
    }
  });

  it("sends an action without a read-back even when one was asked for", async () => {
    const cloud = fakeCloud();
    const vacuum = {
      id: "vac1", name: "扫地机", roomId: "hall", roomName: "客厅", model: "unit.vac.v1", isOnline: true,
      kind: { kind: "vacuum", entityId: "miot:vac1:2", status: "idle", batteryLevel: null },
    } as unknown as SmartDevice;
    const result = await miProvider(cloud, vacuumSpec, [vacuum]).execute(
      { kind: "vacuumAction", entityId: "miot:vac1:2", action: "start" },
      { readBackPower: true },
    );
    assert.equal(result, null);
    assert.deepEqual(cloud.log, ["resolveSpec", "action:2.1"]);
  });
});
