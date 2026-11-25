import assert from "node:assert/strict";
import { test } from "node:test";
import { miAccountId } from "../src/core/pollingPolicy.js";
import { classifyControlFailure } from "../src/core/controlFailure.js";
import { MiCloudClient, MiCloudError, type MiSession } from "../src/core/miCloudClient.js";
import { MiCloudRateLimiter } from "../src/core/miCloud/rateLimiter.js";

const session: MiSession = {
  userId: "100", cUserId: "c", ssecurity: "AQIDBA==", serviceToken: "token", passToken: "", region: "cn",
};

test("polls cannot take the write reserve and writes can borrow a refilled read token", async () => {
  let now = 0;
  const limiter = new MiCloudRateLimiter(() => now);
  for (let i = 0; i < 12; i++) {
    assert.equal((await limiter.admit("a", false)).kind, "admitted");
  }
  assert.deepEqual(await limiter.admit("a", false), { kind: "wait", delayMs: 500 });
  for (let i = 0; i < 8; i++) {
    assert.equal((await limiter.admit("a", true)).kind, "admitted");
  }
  assert.equal((await limiter.admit("a", true)).kind, "limited");
  now = 500;
  assert.equal((await limiter.admit("a", true)).kind, "admitted");
  assert.deepEqual(await limiter.admit("a", false), { kind: "wait", delayMs: 500 });
});

for (const header of ["30", "Thu, 01 Jan 1970 00:00:30 GMT"]) {
  test(`Retry-After ${header} pauses only reads on the limited account`, async () => {
    let now = 0;
    const limiter = new MiCloudRateLimiter(() => now, () => 0, () => 0.5);
    await limiter.recordLimit("a", header);
    assert.equal(limiter.readCooldownMs("a"), 60_000);
    assert.equal((await limiter.admit("b", false)).kind, "admitted");
    for (let i = 0; i < 8; i++) {
      assert.equal((await limiter.admit("a", true)).kind, "admitted");
    }
    assert.equal((await limiter.admit("a", true)).kind, "limited");
    now = 59_999;
    assert.equal((await limiter.admit("a", false)).kind, "limited");
    now = 60_000;
    assert.equal((await limiter.admit("a", false)).kind, "admitted");
  });
}

test("Full Jitter covers the entire exponential window and stale success cannot reset it", async () => {
  for (const sample of [0, 0.25, 1]) {
    const limiter = new MiCloudRateLimiter(() => 0, () => 0, () => sample);
    await limiter.recordLimit("a", "invalid");
    assert.equal(limiter.readCooldownMs("a"), 60_000 * sample);
    await limiter.recordReadSuccess("a", 0);
    await limiter.recordLimit("a", undefined);
    assert.equal(limiter.readCooldownMs("a"), 120_000 * sample);
    for (let i = 0; i < 5; i++) await limiter.recordLimit("a", undefined);
    assert.equal(limiter.readCooldownMs("a"), 900_000 * sample);
  }
});

for (const status of [429, 200]) {
  test(`cloud response ${status} shares cooldown across clients and sends a write once`, async () => {
    const limiter = new MiCloudRateLimiter(() => 0, () => 0, () => 0);
    const paths: string[] = [];
    const transport = async ({ url }: { url: string }) => {
      paths.push(new URL(url).pathname);
      return { status, headers: { "rEtRy-AfTeR": "30" }, body: '{"code":-429,"message":"busy"}' };
    };
    const poll = new MiCloudClient(session, transport, limiter);
    const controls = new MiCloudClient({ ...session, serviceToken: "newToken" }, transport, limiter);
    const isRateLimit = (error: unknown) =>
      error instanceof MiCloudError && error.code === (status === 429 ? 429 : -429);

    await assert.rejects(() => poll.deviceList(), isRateLimit);
    assert.equal(controls.readCooldownMs, 30_000);
    await assert.rejects(() => controls.homeRooms(), { code: 429 });
    const writes = [{ did: "1", siid: 2, piid: 1, value: true }];
    await assert.rejects(() => controls.setProps(writes, undefined, false), { code: 429 });
    await assert.rejects(() => controls.setProps(writes), (error: unknown) =>
      isRateLimit(error) && classifyControlFailure(error)?.kind === "rateLimited",
    );
    assert.deepEqual(paths, ["/app/v2/home/device_list_page", "/app/miotspec/prop/set"]);
  });
}

test("LAN reads and controls bypass a paused cloud account", async () => {
  const limiter = new MiCloudRateLimiter(() => 0, () => 0, () => 0);
  await limiter.recordLimit(miAccountId(session), "60");
  const client = new MiCloudClient(session, async () => assert.fail("Unexpected cloud request"), limiter);
  const device = MiCloudClient.parseDeviceRecord({
    did: "1001", model: "test.light", localip: "192.168.0.5", token: "0123456789abcdef".repeat(2),
  });
  assert.ok(device);
  const power = { did: "1001", siid: 2, piid: 1 };
  const calls: string[] = [];
  client.withLAN([device], [], async <T>(command: string): Promise<T> => {
    calls.push(command);
    return (command === "miio_get_props" ? { values: [{ ...power, value: true }] } : {}) as T;
  });
  assert.deepEqual(await client.getProps([power]), new Map([["1001.2.1", true]]));
  await client.setProps([{ ...power, value: false }], undefined, false);
  assert.deepEqual(calls, ["miio_get_props", "miio_set_props"]);
});
