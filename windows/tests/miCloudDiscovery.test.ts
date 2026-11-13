import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { discoverMiHome, type MiDiscoveryOptions } from "../src/core/miCloud/discovery.js";
import { MiCloudError } from "../src/core/miCloudClient.js";
import type { MiDeviceRecord, MiRoom } from "../src/core/miCloudClient.js";

// Which devices and rooms an account has, without the app. The panel-level behaviour of the same
// rules is pinned in `miCloudSync.test.ts`.

function record(did: string, extra: Partial<MiDeviceRecord> = {}): MiDeviceRecord {
  return { did, name: did, model: "unit.light.v1", isOnline: true, specType: null, ...extra };
}

function room(id: string, dids: string[], extra: Partial<MiRoom> = {}): MiRoom {
  return { id, name: id, dids, ...extra };
}

interface FakeAccount {
  devices?: MiDeviceRecord[];
  rooms?: MiRoom[] | Error;
  byDid?: Record<string, MiDeviceRecord> | Error;
  byHome?: Record<string, MiDeviceRecord[] | Error>;
}

function fakeClient(account: FakeAccount) {
  const calls: string[] = [];
  return {
    calls,
    client: {
      async deviceList() {
        calls.push("deviceList");
        return account.devices ?? [];
      },
      async homeRooms() {
        calls.push("homeRooms");
        if (account.rooms instanceof Error) throw account.rooms;
        return account.rooms ?? [];
      },
      async devicesByDids(dids: string[]) {
        calls.push(`devicesByDids:${dids.join(",")}`);
        if (account.byDid instanceof Error) throw account.byDid;
        const known = account.byDid ?? {};
        return dids.flatMap((did) => (known[did] ? [known[did]] : []));
      },
      async homeDevices(homeId: string, ownerUid: string) {
        calls.push(`homeDevices:${homeId}:${ownerUid}`);
        const answer = account.byHome?.[homeId] ?? [];
        if (answer instanceof Error) throw answer;
        return answer;
      },
    },
  };
}

function options(overrides: Partial<MiDiscoveryOptions> = {}): MiDiscoveryOptions & { read: MiRoom[][] } {
  const read: MiRoom[][] = [];
  return {
    unresolvedDids: new Set<string>(),
    retryUnresolved: false,
    cachedRooms: () => null,
    onRoomsRead: (rooms) => read.push(rooms),
    read,
    ...overrides,
  };
}

const expired = new MiCloudError("sessionExpired", "登录已过期");

describe("discoverMiHome", () => {
  it("keeps a normal account to the two requests it always made", async () => {
    const { client, calls } = fakeClient({
      devices: [record("a"), record("b")],
      rooms: [room("living", ["a", "b"], { homeId: "h1", ownerUid: "u1" })],
    });
    const opts = options();
    const found = await discoverMiHome(client, opts);
    assert.deepEqual(calls.sort(), ["deviceList", "homeRooms"]);
    assert.deepEqual(found.devices.map((d) => d.did), ["a", "b"]);
    assert.equal(found.roomsError, null);
    assert.equal(opts.read.length, 1, "a room read that answered is handed to the caller to cache");
  });

  it("looks up a did a room names but the list left out", async () => {
    const { client, calls } = fakeClient({
      devices: [record("a")],
      rooms: [room("living", ["a", "shared"])],
      byDid: { shared: record("shared") },
    });
    const found = await discoverMiHome(client, options());
    assert.ok(calls.includes("devicesByDids:shared"));
    assert.deepEqual(found.devices.map((d) => d.did), ["a", "shared"]);
  });

  it("remembers a did no lookup resolved and skips it until asked to retry", async () => {
    const account: FakeAccount = { devices: [record("a")], rooms: [room("living", ["a", "ghost"])] };
    const unresolvedDids = new Set<string>();

    const first = fakeClient(account);
    await discoverMiHome(first.client, options({ unresolvedDids }));
    assert.deepEqual([...unresolvedDids], ["ghost"]);

    const second = fakeClient(account);
    await discoverMiHome(second.client, options({ unresolvedDids }));
    assert.ok(!second.calls.some((call) => call.startsWith("devicesByDids")), "a background refresh does not ask again");

    const third = fakeClient(account);
    await discoverMiHome(third.client, options({ unresolvedDids, retryUnresolved: true }));
    assert.ok(third.calls.includes("devicesByDids:ghost"), "a manual refresh asks again");
  });

  it("asks a shared home directly when its dids produced nothing, and buckets unnamed devices", async () => {
    const { client, calls } = fakeClient({
      devices: [],
      rooms: [room("r1", ["x"], { homeId: "h2", homeName: "爸妈家", ownerUid: "u2", isSharedHome: true })],
      byHome: { h2: [record("x"), record("y")] },
    });
    const unresolvedDids = new Set<string>();
    const found = await discoverMiHome(client, options({ unresolvedDids }));
    assert.ok(calls.includes("homeDevices:h2:u2"));
    assert.deepEqual(found.devices.map((d) => d.did), ["x", "y"]);
    assert.deepEqual([...unresolvedDids], [], "a did the home listing found is no longer unresolved");
    const bucket = found.rooms.find((r) => r.id === "home_h2");
    assert.deepEqual(bucket?.dids, ["y"], "a device no room names lands in the home's room-less bucket");
    assert.equal(bucket?.homeName, "爸妈家");
    assert.equal(bucket?.isSharedHome, true);
    assert.equal(bucket?.ownerUid, "u2");
  });

  it("keeps a split key in its parent's room instead of the room-less bucket", async () => {
    const { client } = fakeClient({
      devices: [],
      rooms: [room("r1", ["panel"], { homeId: "h2", ownerUid: "u2" })],
      byHome: { h2: [record("panel"), record("panel.s2", { splitParentDid: "panel" })] },
    });
    const found = await discoverMiHome(client, options());
    assert.deepEqual(found.devices.map((d) => d.did), ["panel", "panel.s2"]);
    assert.equal(found.rooms.find((r) => r.id === "home_h2"), undefined);
  });

  it("falls back to cached rooms when the room read fails but devices answered", async () => {
    const failure = new Error("HTTP 500");
    const cached = [room("living", ["a"])];
    const { client } = fakeClient({ devices: [record("a")], rooms: failure });
    const opts = options({ cachedRooms: () => cached });
    const found = await discoverMiHome(client, opts);
    assert.equal(found.roomsError, failure);
    assert.deepEqual(found.rooms, cached);
    assert.notEqual(found.rooms, cached, "the cache is copied, not handed out");
    assert.equal(opts.read.length, 0, "a failed read does not replace the cache");
  });

  it("uses no rooms when the room read fails and nothing is cached", async () => {
    const { client } = fakeClient({ devices: [record("a")], rooms: new Error("HTTP 500") });
    const found = await discoverMiHome(client, options());
    assert.deepEqual(found.rooms, []);
    assert.deepEqual(found.devices.map((d) => d.did), ["a"]);
  });

  it("reports a failed room read instead of an empty account", async () => {
    const failure = new Error("HTTP 500");
    const { client } = fakeClient({ devices: [], rooms: failure });
    await assert.rejects(discoverMiHome(client, options()), (error) => error === failure);
  });

  it("reports an expired session from the room read even when the device list answered", async () => {
    const { client } = fakeClient({ devices: [record("a")], rooms: expired });
    await assert.rejects(discoverMiHome(client, options()), (error) => error === expired);
  });

  it("reports an expired session from either lookup", async () => {
    const byDid = fakeClient({ devices: [record("a")], rooms: [room("r", ["a", "b"])], byDid: expired });
    await assert.rejects(discoverMiHome(byDid.client, options()), (error) => error === expired);

    const byHome = fakeClient({
      devices: [],
      rooms: [room("r", [], { homeId: "h", ownerUid: "u" })],
      byHome: { h: expired },
    });
    await assert.rejects(discoverMiHome(byHome.client, options()), (error) => error === expired);
  });

  it("keeps the listed devices when a lookup fails for another reason", async () => {
    const { client } = fakeClient({
      devices: [record("a")],
      rooms: [room("r", ["a", "b"])],
      byDid: new Error("HTTP 502"),
    });
    const found = await discoverMiHome(client, options());
    assert.deepEqual(found.devices.map((d) => d.did), ["a"]);
  });

  it("reports the first lookup failure when it leaves no devices at all", async () => {
    const first = new Error("HTTP 502");
    const { client } = fakeClient({
      devices: [],
      rooms: [room("r", ["b"], { homeId: "h", ownerUid: "u" })],
      byDid: first,
      byHome: { h: new Error("HTTP 503") },
    });
    await assert.rejects(discoverMiHome(client, options()), (error) => error === first);
  });
});
