import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { MiCloudClient, type MiDeviceRecord, type MiRoom } from "../src/core/miCloud/client.js";
import { MiIOUnconfirmedWriteError } from "../src/core/miCloud/localMiIO.js";
import { MiCloudError } from "../src/core/miCloud/session.js";

const token = "0123456789abcdef0123456789abcdef";
const power = { did: "1001", siid: 2, piid: 1 };
const brightness = { did: "1001", siid: 2, piid: 2 };
const writes = [{ ...power, value: true }, { ...brightness, value: 50 }];
const action = { did: "1001", siid: 3, aiid: 1, inputs: [] };

function record(fields: Record<string, unknown> = {}): MiDeviceRecord {
  return MiCloudClient.parseDeviceRecord({
    did: "1001", model: "test.light", localip: "192.168.0.5", token, ...fields,
  })!;
}

function fixture(
  native: (command: string, args: Record<string, unknown>) => unknown,
  devices = [record()],
  rooms: readonly MiRoom[] = [],
) {
  const lan: string[] = [];
  const cloud: { api: string; data: unknown }[] = [];
  const session = { userId: "1", cUserId: "", region: "cn", ssecurity: "", serviceToken: "", passToken: "" };
  const client = new MiCloudClient(session, async () => { throw new Error("Real network is disabled"); })
    .withLAN(devices, rooms, async <T>(command: string, args?: Record<string, unknown>) => {
      lan.push(command);
      return native(command, args ?? {}) as T;
    });
  client.request = async (api, data) => {
    cloud.push({ api, data });
    if (api === "miotspec/prop/get") {
      return (data as { params: object[] }).params.map((key) => ({ ...key, code: 0, value: 55 }));
    }
    return api === "miotspec/prop/set" ? [{ code: 0 }, { code: 0 }] : { code: 0 };
  };
  return { client, lan, cloud };
}

describe("Xiaomi LAN-first routing", () => {
  it("uses native reads, property writes and actions without cloud requests", async () => {
    const { client, lan, cloud } = fixture((command, args) => {
      assert.deepEqual(args["endpoint"], { did: "1001", ip: "192.168.0.5", token });
      switch (command) {
        case "miio_get_props": return { values: [{ ...power, value: true }] };
        case "miio_set_props":
          assert.deepEqual(args["writes"], writes);
          return { rttMs: 1 };
        case "miio_call_action":
          assert.deepEqual(args["call"], action);
          return { result: { code: 0, out: [1] } };
        default: assert.fail(command);
      }
    });
    assert.deepEqual(await client.getProps([power]), new Map([["1001.2.1", true]]));
    await client.setProps(writes);
    assert.deepEqual(await client.callAction(action), { code: 0, out: [1] });
    assert.deepEqual(lan, ["miio_get_props", "miio_set_props", "miio_call_action"]);
    assert.deepEqual(cloud, []);
  });

  it("fills only missing keys from cloud and discards unrequested LAN values", async () => {
    const { client, cloud } = fixture(() => ({ values: [
      { ...power, value: true }, { ...brightness, did: "another-device", value: 90 },
    ] }));
    assert.deepEqual(await client.getProps([power, brightness]),
      new Map<string, unknown>([["1001.2.1", true], ["1001.2.2", 55]]));
    assert.deepEqual(cloud, [{ api: "miotspec/prop/get", data: { params: [brightness] } }]);
  });

  it("falls back after a read timeout or a write that could not be sent", async () => {
    const { client, cloud } = fixture((command) => {
      throw { code: command === "miio_get_props" ? "timeout" : "write_not_sent" };
    });
    await client.getProps([power]);
    let checked = false;
    await client.setProps(writes, () => { checked = true; });
    assert.ok(checked);
    await client.callAction(action);
    assert.deepEqual(cloud.map(({ api }) => api), ["miotspec/prop/get", "miotspec/prop/set", "miotspec/action"]);
  });

  it("checks the current write gate again before cloud fallback", async () => {
    const { client, cloud } = fixture(() => { throw { code: "write_not_sent" }; });
    await assert.rejects(client.callAction(action, async () => { throw new Error("source switched"); }),
      /source switched/);
    assert.deepEqual(cloud, []);
  });

  it("never replays partial acknowledgements or an action with a lost reply", async () => {
    const { client, lan, cloud } = fixture((command) => {
      throw { code: command === "miio_set_props" ? "ambiguous_write_outcome" : "ambiguous_action_outcome" };
    });
    await assert.rejects(client.setProps(writes), MiIOUnconfirmedWriteError);
    await assert.rejects(client.callAction(action), MiIOUnconfirmedWriteError);
    assert.deepEqual(lan, ["miio_set_props", "miio_call_action"]);
    assert.deepEqual(cloud, []);
  });

  it("does not replay an explicit rejection, a raw timeout, or an unknown IPC failure", async () => {
    for (const error of [{ code: "device_error", deviceCode: -704002000 }, { code: "timeout" }, "IPC failed"]) {
      const { client, cloud } = fixture(() => { throw error; });
      await assert.rejects(client.action(action), (actual) => typeof error !== "string" && error.code === "device_error"
        ? actual instanceof MiCloudError && actual.code === error.deviceCode
        : actual instanceof MiIOUnconfirmedWriteError);
      assert.deepEqual(cloud, []);
    }
  });

  it("keeps tokens out of records and sends ineligible devices directly to the cloud", async () => {
    assert.equal(JSON.stringify(record()).includes(token), false);
    assert.equal(JSON.stringify(structuredClone(record())).includes(token), false);
    for (const fields of [
      { token: "" }, { localip: "8.8.8.8" }, { isOnline: false }, { share_flag: 1 },
      { extra: { split: { parentId: "1002", moduleId: 2 } } },
    ]) {
      const { client, lan } = fixture(() => assert.fail(), [record(fields)]);
      await client.getProps([power]);
      await client.action(action);
      assert.deepEqual(lan, []);
    }
    const { client, lan } = fixture(() => assert.fail(), [record()],
      [{ id: "shared", name: "shared", dids: [power.did], isSharedHome: true }]);
    await client.action(action);
    assert.deepEqual(lan, []);
  });
});
