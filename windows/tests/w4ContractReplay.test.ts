import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { IntentReply } from "../src/core/assistant.js";
import { HAHomeSnapshot } from "../src/core/homeAssistant.js";
import { buildHomeOptionsFromMiRooms } from "../src/core/miAccountsStore.js";
import {
  MiCloudClient,
  MiotCommandMapper,
  MiotSynthesizer,
  miotDid,
  miotShortName,
  parseMiotDeviceSpec,
  parseMiotInstanceIndex,
  propKeyString,
  type MiDeviceRecord,
  type MiRoom,
  type MiSession,
  type MiotDeviceSpec,
} from "../src/core/miCloudClient.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONTRACTS_DIR = path.resolve(__dirname, "../../Tests/Fixtures/contracts");

const EXPECTED_CONTRACT_FILES = [
  "ha_websocket_messages.json",
  "mi_dev_room_page.json",
  "mi_device_list_page.json",
  "mi_group_query_status.json",
  "mi_home_rooms_merged.json",
  "mi_props_get.json",
  "miio_get_properties.json",
  "miot_instance_index.json",
  "miot_spec_light.json",
] as const;

function readContractRaw(fileName: string): string {
  return readFileSync(path.join(CONTRACTS_DIR, fileName), "utf8");
}

function decodeContractFixture(fileName: string): Record<string, unknown> {
  const raw = readContractRaw(fileName);
  const parsed: unknown = JSON.parse(raw);
  assert.ok(parsed && typeof parsed === "object" && !Array.isArray(parsed), `${fileName} root must be an object`);
  const root = parsed as Record<string, unknown>;
  const meta = root._fixture;
  assert.ok(meta && typeof meta === "object" && !Array.isArray(meta), `${fileName} missing _fixture metadata`);
  const metaObj = meta as Record<string, unknown>;
  for (const field of ["endpoint", "captured", "sanitised", "shape"] as const) {
    assert.equal(typeof metaObj[field], "string", `${fileName} _fixture.${field} must be string`);
    assert.ok((metaObj[field] as string).trim().length > 0, `${fileName} _fixture.${field} must be non-empty`);
  }
  return root;
}

function isPrivateOrLoopbackIPv4(ip: string): boolean {
  const parts = ip.split(".").map((part) => Number(part));
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = parts as [number, number, number, number];
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 169 && b === 254) return true;
  return false;
}

describe("D4 Contract Replay · Fixture hygiene & metadata audit", () => {
  it("discovers all contract fixtures with complete _fixture blocks and zero private LAN/loopback IPs", () => {
    const discovered = readdirSync(CONTRACTS_DIR)
      .filter((name) => name.endsWith(".json"))
      .sort();
    assert.deepEqual(discovered, [...EXPECTED_CONTRACT_FILES]);

    const ipv4Candidate = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;
    for (const fileName of discovered) {
      const raw = readContractRaw(fileName);
      const doc = decodeContractFixture(fileName);
      assert.ok(/^\d{4}-\d{2}-\d{2}$/.test((doc._fixture as Record<string, string>).captured!));

      for (const match of raw.matchAll(ipv4Candidate)) {
        const ip = match[0]!;
        assert.equal(
          isPrivateOrLoopbackIPv4(ip),
          false,
          `${fileName} contains non-sanitised private/loopback IP ${ip} (use RFC 5737 TEST-NET such as 192.0.2.x)`,
        );
      }
    }
  });
});

describe("D4 Contract Replay · Xiaomi Cloud & local miIO envelopes (ContractReplayTests.swift parity)", () => {
  it("replays mi_device_list_page.json and preserves device fields, split metadata & hostile numeric IDs", () => {
    const doc = decodeContractFixture("mi_device_list_page.json");
    const result = MiCloudClient.unwrapResult(doc) as Record<string, unknown>;
    const records = MiCloudClient.parseDeviceList(result);

    assert.deepEqual(records, [
      {
        did: "did-light-0001",
        name: "Contract Ceiling Light",
        model: "yeelink.light.ceiling22",
        isOnline: true,
        specType: "urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling22:2",
        localIp: "192.0.2.10",
        mac: "02:00:00:00:00:01",
      },
      {
        did: "did-switch-0002.s2",
        name: "Contract Downlight",
        model: "lemesh.switch.sw2f12",
        isOnline: false,
        specType: null,
        splitParentDid: "did-switch-0002",
        splitSiid: 2,
      },
      {
        did: "did-camera-0003",
        name: "Contract Camera",
        model: "chuangmi.camera.81ac1",
        isOnline: true,
        specType: null,
        localIp: "192.0.2.11",
        mac: "02:00:00:00:00:03",
      },
    ]);

    const split = records.find((r) => r.splitParentDid != null);
    assert.ok(split);
    assert.equal(miotDid(split), "did-switch-0002");
    assert.equal(result.next_start_did, "");
    assert.equal(result.has_more, false);

    const hostileRecords = MiCloudClient.parseDeviceList({
      list: [
        { did: 1e308, model: "contract.ghost" },
        { did: 42, model: "contract.numeric" },
        { did: "did-light-0001", model: "contract.light" },
      ],
    });
    assert.deepEqual(hostileRecords.map((r) => r.did), ["42", "did-light-0001"]);

    const reply = IntentReply.describe(
      [{ targetId: "did-light-0001", operation: { kind: "brightnessStep", delta: Number.MIN_SAFE_INTEGER } }],
      [],
      [],
    );
    assert.ok(reply.includes("did-light-0001") && !reply.includes("NaN") && !reply.includes("Infinity"));
  });

  it("replays mi_home_rooms_merged.json + mi_dev_room_page.json and matches macOS home options & merged rooms", () => {
    const mergedDoc = decodeContractFixture("mi_home_rooms_merged.json");
    const result = MiCloudClient.unwrapResult(mergedDoc);
    const rooms = MiCloudClient.parseRooms(result);

    assert.deepEqual(rooms, [
      { id: "room-2001", name: "Living Room", dids: ["did-light-0001"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2002", name: "Study", dids: ["did-camera-0003"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2003", name: "Kitchen", dids: [], homeId: "home-1002", homeName: "Contract Beach House" },
      { id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true },
    ]);
    assert.ok(!rooms.some((r) => r.id === "room-9999"));

    assert.deepEqual(buildHomeOptionsFromMiRooms(rooms), [
      { id: "home-1001", name: "Contract Home", deviceCount: 3 },
      { id: "home-1002", name: "Contract Beach House", deviceCount: 0 },
      { id: "home-1003", name: "Contract Shared Home", deviceCount: 1, isSharedHome: true },
    ]);

    const pageDoc = decodeContractFixture("mi_dev_room_page.json");
    const page = MiCloudClient.unwrapResult(pageDoc);
    const merged = MiCloudClient.mergeRoomPage(page, rooms);

    assert.deepEqual(merged, [
      { id: "room-2001", name: "Living Room", dids: ["did-light-0001", "did-plug-0004"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2002", name: "Study", dids: ["did-camera-0003", "did-fan-0006"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002", "did-sensor-0005"], homeId: "home-1001", homeName: "Contract Home" },
      { id: "room-2003", name: "Kitchen", dids: ["did-fridge-0008"], homeId: "home-1002", homeName: "Contract Beach House" },
      { id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true },
      { id: "home_home-1002", name: "", dids: ["did-kettle-0007"], homeId: "home-1002", homeName: "Contract Beach House" },
    ]);
  });

  it("replays mi_group_query_status.json and tolerates both member_ship and membership spellings", () => {
    const doc = decodeContractFixture("mi_group_query_status.json");
    const result = MiCloudClient.unwrapResult(doc);
    const members = MiCloudClient.parseLightGroupMembers(result);

    assert.deepEqual([...members.keys()].sort(), ["group.1000001", "group.1000002"]);
    assert.deepEqual([...(members.get("group.1000001") ?? [])].sort(), ["did-light-0001", "did-light-0002"]);
    assert.deepEqual(members.get("group.1000002"), ["did-light-0003"]);
  });

  it("replays mi_props_get.json through both static parsePropValues and MiCloudClient.getProps", async () => {
    const raw = readContractRaw("mi_props_get.json");
    const doc = decodeContractFixture("mi_props_get.json");
    const result = MiCloudClient.unwrapResult(doc);
    const expected = new Map<string, unknown>([
      ["did-light-0001.2.1", true],
      ["did-light-0001.2.2", 80],
      ["did-light-0001.2.3", 4000],
      ["did-camera-0003.2.1", "off"],
    ]);

    assert.deepEqual(MiCloudClient.parsePropValues(result), expected);

    const session: MiSession = {
      userId: "10001",
      cUserId: "c1",
      passToken: "pass-tok",
      ssecurity: Buffer.alloc(16, 1).toString("base64"),
      serviceToken: "tok",
      region: "cn",
    };
    const client = new MiCloudClient(session, async () => ({
      status: 200,
      headers: {},
      body: raw,
    }));
    const viaTransport = await client.getProps([
      { did: "did-light-0001", siid: 2, piid: 1 },
      { did: "did-light-0001", siid: 2, piid: 2 },
      { did: "did-light-0001", siid: 2, piid: 3 },
      { did: "did-camera-0003", siid: 2, piid: 1 },
    ]);
    assert.deepEqual(viaTransport, expected);
  });

  it("replays miio_get_properties.json and resets stale lock door-state to unknown when all codes are nonzero", () => {
    const doc = decodeContractFixture("miio_get_properties.json");
    const mixedEnvelope = doc.mixedReply as Record<string, unknown>;
    const mixed = MiCloudClient.parsePropValues(mixedEnvelope.result, {
      defaultDid: "did-light-0001",
      dropNullValues: true,
    });
    assert.deepEqual(
      mixed,
      new Map<string, unknown>([
        ["did-light-0001.2.1", true],
        ["did-light-0001.2.2", 80],
        ["did-light-0001.2.3", 4200],
      ]),
    );

    const allNonzeroEnvelope = doc.allNonzeroLockReply as Record<string, unknown>;
    const lockEmpty = MiCloudClient.parsePropValues(allNonzeroEnvelope.result, {
      defaultDid: "did-lock-0001",
      dropNullValues: true,
    });
    assert.equal(lockEmpty.size, 0);

    const malformed = MiCloudClient.parsePropValues(
      [
        { did: "did-lock-0001", siid: 2, piid: 1, value: 1, code: 1e308 },
        { did: "did-lock-0001", siid: 3, piid: 1, value: null, code: 0 },
      ],
      { defaultDid: "did-lock-0001", dropNullValues: true },
    );
    assert.equal(malformed.size, 0);

    const lockSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:lock:0000A038:contract:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:lock:00007855:contract:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:door-state:00000001:contract:1",
              format: "uint8",
              access: ["read", "notify"],
              valueList: [
                { value: 1, description: "Locked" },
                { value: 2, description: "Unlocked" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:battery:00007805:contract:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:battery-level:00000014:contract:1",
              format: "uint8",
              access: ["read"],
            },
          ],
          actions: [],
        },
      ],
    };
    const lightSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:contract:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:contract:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:contract:1", format: "bool", access: ["read", "write", "notify"] },
            { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:contract:1", format: "uint8", access: ["read", "write", "notify"], valueRange: [1, 100, 1] },
            { iid: 3, type: "urn:miot-spec-v2:property:color-temperature:0000000F:contract:1", format: "uint32", access: ["read", "write", "notify"], valueRange: [2700, 6500, 1] },
          ],
          actions: [],
        },
      ],
    };
    const records: readonly MiDeviceRecord[] = [
      { did: "did-lock-0001", name: "Contract Front Lock", model: "xiaomi.lock.contract", isOnline: true, specType: lockSpec.type },
      { did: "did-light-0001", name: "Contract Ceiling Light", model: "yeelink.light.contract", isOnline: true, specType: lightSpec.type },
    ];
    const rooms: readonly MiRoom[] = [
      { id: "room-contract", name: "Entry", dids: ["did-lock-0001", "did-light-0001"] },
    ];
    const specs = {
      "xiaomi.lock.contract": lockSpec,
      "yeelink.light.contract": lightSpec,
    };

    const poll1Values = new Map<string, unknown>([
      ...mixed,
      [propKeyString({ did: "did-lock-0001", siid: 2, piid: 1 }), 1],
      [propKeyString({ did: "did-lock-0001", siid: 3, piid: 1 }), 85],
    ]);
    const poll1Home = MiotSynthesizer.synthesize(records, rooms, specs, poll1Values);
    const poll1Lock = poll1Home.devices.find((d) => d.id === "did-lock-0001");
    assert.equal(poll1Lock?.kind.kind, "sensor");
    if (poll1Lock?.kind.kind === "sensor") {
      assert.ok(poll1Lock.kind.statusText === "已上锁" || poll1Lock.kind.statusText === "Locked");
    }

    const poll2Values = new Map<string, unknown>([...mixed, ...lockEmpty]);
    const poll2Home = MiotSynthesizer.synthesize(records, rooms, specs, poll2Values);
    const poll2Lock = poll2Home.devices.find((d) => d.id === "did-lock-0001");
    assert.equal(poll2Lock?.kind.kind, "sensor");
    if (poll2Lock?.kind.kind === "sensor") {
      assert.ok(poll2Lock.kind.statusText === "锁状态未知" || poll2Lock.kind.statusText === "Lock status unknown");
    }
    const poll2Light = poll2Home.devices.find((d) => d.id === "did-light-0001");
    assert.equal(poll2Light?.kind.kind, "light");
    if (poll2Light?.kind.kind === "light") {
      assert.equal(poll2Light.kind.isOn, true);
      assert.equal(poll2Light.kind.brightnessPercent, 80);
      assert.equal(poll2Light.kind.colorTempKelvin, 4200);
    }
  });
});

describe("D4 Contract Replay · MIoT spec, MIoT instance index & Home Assistant WebSocket stream", () => {
  it("replays miot_spec_light.json across parseMiotDeviceSpec, MiotSynthesizer & MiotCommandMapper", () => {
    const doc = decodeContractFixture("miot_spec_light.json");
    const spec = parseMiotDeviceSpec(doc);
    assert.ok(spec);

    assert.equal(miotShortName(spec.type), "light");
    assert.equal(spec.description, "Light");

    const service = spec.services.find((s) => s.iid === 2);
    assert.ok(service);
    assert.equal(miotShortName(service.type), "light");

    const onProp = service.properties.find((p) => miotShortName(p.type) === "on");
    assert.ok(onProp);
    assert.equal(onProp.format, "bool");
    assert.ok(onProp.access.includes("read") && onProp.access.includes("write"));
    assert.equal(onProp.valueRange, undefined);
    assert.equal(onProp.valueList, undefined);

    const brightness = service.properties.find((p) => miotShortName(p.type) === "brightness");
    assert.ok(brightness);
    assert.ok(brightness.format.startsWith("uint") || brightness.format.startsWith("int"));
    assert.equal(brightness.unit, "percentage");
    assert.deepEqual(brightness.valueRange, [1, 100, 1]);

    const colorTemp = service.properties.find((p) => miotShortName(p.type) === "color-temperature");
    assert.ok(colorTemp);
    assert.deepEqual(colorTemp.valueRange?.slice(0, 2), [2700, 6500]);

    const mode = service.properties.find((p) => miotShortName(p.type) === "mode");
    assert.ok(mode);
    assert.deepEqual(mode.valueList?.map((v) => v.value), [0, 1]);
    assert.equal(mode.valueList?.find((v) => v.value === 1)?.description, "Sleep");
    assert.equal(mode.valueList?.find((v) => v.value === 42), undefined);

    const toggle = service.actions.find((a) => miotShortName(a.type) === "toggle");
    const setBri = service.actions.find((a) => miotShortName(a.type) === "set-brightness");
    assert.deepEqual(toggle?.in ?? [], []);
    assert.deepEqual(setBri?.in ?? [], [2]);

    const home = MiotSynthesizer.synthesize(
      [{ did: "did-light-0001", name: "Contract Light", model: "contract.light", isOnline: true, specType: spec.type }],
      [{ id: "room-2001", name: "Living Room", dids: ["did-light-0001"] }],
      { "contract.light": spec },
      new Map<string, unknown>([
        ["did-light-0001.2.1", true],
        ["did-light-0001.2.2", 80],
        ["did-light-0001.2.3", 4000],
        ["did-light-0001.2.4", 1],
      ]),
    );
    const light = home.devices[0];
    assert.equal(light?.kind.kind, "light");
    if (light?.kind.kind === "light") {
      assert.equal(light.kind.isOn, true);
      assert.equal(light.kind.brightnessPercent, 80);
      assert.equal(light.kind.colorTempKelvin, 4000);
      assert.equal(light.kind.currentEffect, "Sleep");
      assert.deepEqual(light.kind.availableEffects, ["Auto", "Sleep"]);

      const mapped = MiotCommandMapper.map(
        { kind: "setLightBrightness", entityId: light.kind.entityId, percent: 65 },
        spec,
      );
      assert.deepEqual(mapped, {
        kind: "setProps",
        writes: [
          { did: "did-light-0001", siid: 2, piid: 1, value: true },
          { did: "did-light-0001", siid: 2, piid: 2, value: 65 },
        ],
      });
    }
  });

  it("replays miot_instance_index.json and keeps the highest released version per model", () => {
    const doc = decodeContractFixture("miot_instance_index.json");
    const index = parseMiotInstanceIndex(doc);
    assert.deepEqual(index, {
      "contract.light.ceiling": "urn:miot-spec-v2:device:light:0000A001:contract-light:3",
      "contract.plug.v1": "urn:miot-spec-v2:device:outlet:0000A002:contract-plug:2",
    });
  });

  it("replays ha_websocket_messages.json across HAHomeSnapshot.receive with 1:1 macOS field parity", () => {
    const doc = decodeContractFixture("ha_websocket_messages.json");
    assert.ok(Array.isArray(doc.messages), "ha_websocket_messages.json must contain messages array");

    const snapshot = new HAHomeSnapshot();
    const homes = [];
    for (const message of doc.messages) {
      const home = snapshot.receive(message);
      if (home) homes.push(home);
    }

    assert.equal(homes.length, 3);

    const initial = homes[0]!;
    assert.deepEqual(
      initial.devices.map((d) => d.id).sort(),
      ["dev-light-01", "dev-thermo-02"],
    );

    const light = initial.devices.find((d) => d.id === "dev-light-01");
    assert.ok(light);
    assert.equal(light.name, "Contract Ceiling Light");
    assert.equal(light.roomName, "Living Room");
    assert.equal(light.kind.kind, "light");
    if (light.kind.kind === "light") {
      assert.equal(light.kind.entityId, "light.ceiling");
      assert.equal(light.kind.isOn, true);
      assert.equal(light.kind.brightnessPercent, 50);
      assert.deepEqual(light.kind.availableEffects, ["Reading"]);
    }

    const thermometer = initial.devices.find((d) => d.id === "dev-thermo-02");
    assert.ok(thermometer);
    assert.equal(thermometer.roomName, "Study");
    assert.equal(thermometer.kind.kind, "sensor");
    if (thermometer.kind.kind === "sensor") {
      assert.equal(thermometer.kind.temperature, 23.5);
      assert.equal(thermometer.kind.humidity, 45);
      assert.equal(thermometer.kind.battery, 87);
    }

    assert.equal(initial.devices.some((d) => d.id === "dev-hidden-03"), false);

    const afterEvent = homes[1]!;
    const lightAfterEvent = afterEvent.devices.find((d) => d.id === "dev-light-01");
    assert.equal(lightAfterEvent?.kind.kind, "light");
    if (lightAfterEvent?.kind.kind === "light") {
      assert.equal(lightAfterEvent.kind.isOn, false);
    }

    const refreshed = homes[2]!;
    const lightRefreshed = refreshed.devices.find((d) => d.id === "dev-light-01");
    assert.equal(lightRefreshed?.kind.kind, "light");
    if (lightRefreshed?.kind.kind === "light") {
      assert.equal(lightRefreshed.kind.isOn, true);
      assert.equal(lightRefreshed.kind.brightnessPercent, 100);
    }
  });
});
