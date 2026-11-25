import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import { CHANNEL_WRITE_BATCH_WINDOW_MS, MiCloudChannelWriteBatcher } from "../src/core/miCloud/channelWriteBatcher.js";
import { MiCloudClient, type MiotPropWrite } from "../src/core/miCloud/client.js";
import { MiCloudError, type MiSession } from "../src/core/miCloud/session.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import { MiCloudRateLimiter } from "../src/core/miCloud/rateLimiter.js";
import { miAccountId } from "../src/core/pollingPolicy.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiCloudProvider } from "../src/core/homeProvider.js";
import { setChannelWriteBatcherForTesting } from "../src/ui/commandDispatch.js";
import type { SmartDevice } from "../src/core/models.js";

class SleepGate {
  private waiters: Array<() => void> = [];
  public delays: number[] = [];
  get waiting(): number { return this.waiters.length; }
  sleep(ms: number): Promise<void> {
    this.delays.push(ms);
    return new Promise((resolve) => { this.waiters.push(resolve); });
  }
  release(): void { this.waiters.shift()?.(); }
}

async function waitUntil(predicate: () => boolean, label: string, maxTicks = 200): Promise<void> {
  for (let i = 0; i < maxTicks; i += 1) {
    if (predicate()) return;
    await setImmediate();
  }
  assert.fail(`Timed out waiting for: ${label}`);
}

const CHANNEL_SIIDS = [2, 3, 4, 5] as const;

const makeFourOutletSpec = (): MiotDeviceSpec => ({
  type: "urn:miot-spec-v2:device:outlet:0000A002:test:1",
  services: CHANNEL_SIIDS.map((siid) => ({
    iid: siid,
    type: "urn:miot-spec-v2:service:outlet:00007805:test:1",
    properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test:1", format: "bool", access: ["read", "write"] }],
    actions: [],
  })),
});

const makeFourOutletDevices = (did = "101"): SmartDevice[] =>
  CHANNEL_SIIDS.map((siid) => ({
    id: `${did}.s${siid}`, name: `Outlet ${siid}`, roomId: "room", roomName: "Room",
    model: "test.switch.strip", isOnline: true,
    kind: {
      kind: "plug", switchEntityId: `miot:${did}:${siid}`, isOn: true,
      powerWatts: null, energyKwh: null, childLockEntityId: null, isChildLocked: false, powerWritable: true,
    },
  }));

let dom: Window;
beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  setLanguage("zh-Hans");
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});
afterEach(async () => {
  setLanguage("zh-Hans");
  await closeTestWindow(dom);
});

describe("Multi-channel 100 ms write coalescing (parity with #506 ChannelWriteBatchTests)", () => {
  for (const lockWhilePending of [false, true]) {
    it(`four-outlet off within 100 ms coalesces into one batch and re-checks lock screen (lockWhilePending=${lockWhilePending})`, async () => {
      const did = "101";
      const spec = makeFourOutletSpec();
      const channels = makeFourOutletDevices(did);
      const setPropsCalls: MiotPropWrite[][] = [];
      let workstationLocked = false;

      Object.defineProperty(window, "__TAURI_INTERNALS__", {
        configurable: true,
        value: { invoke: async (cmd: string) => (cmd === "is_workstation_locked" ? workstationLocked : null) },
      });

      const session = { userId: "test", cUserId: "test", region: "cn", ssecurity: "test", serviceToken: "test", passToken: "test" };
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        connectionMode: "xiaomiCloud", hasCompletedOnboarding: true, autoCheckUpdates: false,
        blockControlWhileLocked: true, miSession: session,
        allOffOverrides: Object.fromEntries(channels.map((ch) => [ch.id, true])),
      }));

      const app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
      app.refreshDevices = async () => {};
      app.devices = structuredClone(channels);
      app.specResolver.resolve = async () => spec;

      const origRequest = MiCloudClient.prototype.request;
      MiCloudClient.prototype.request = async function (api: string, data: unknown): Promise<unknown> {
        if (api === "miotspec/prop/set") {
          const params = (data as { params: MiotPropWrite[] }).params;
          setPropsCalls.push(params);
          return params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0 }));
        }
        return origRequest.call(this, api, data);
      };

      const sleepGate = new SleepGate();
      const batcher = new MiCloudChannelWriteBatcher({ sleep: (ms) => sleepGate.sleep(ms) });
      setChannelWriteBatcherForTesting(app, batcher);

      try {
        const intents = channels.map((ch) => ({ targetId: ch.id, operation: { kind: "power" as const, isOn: false } }));
        const run = app.executeIntents(intents, "已关闭 4 台设备", "一键全关");
        await waitUntil(() => batcher.pendingCount(did) === 4 && sleepGate.waiting === 1, "4 channels queued");
        assert.deepEqual(sleepGate.delays, [CHANNEL_WRITE_BATCH_WINDOW_MS]);
        assert.equal(setPropsCalls.length, 0);

        if (lockWhilePending) workstationLocked = true;
        sleepGate.release();
        const ok = await run;

        if (lockWhilePending) {
          assert.equal(ok, false);
          assert.equal(setPropsCalls.length, 0);
          return;
        }
        assert.equal(ok, true);
        assert.equal(setPropsCalls.length, 1);
        assert.deepEqual(
          [...setPropsCalls[0]!].sort((a, b) => a.siid - b.siid),
          CHANNEL_SIIDS.map((siid) => ({ did, siid, piid: 1, value: false })),
        );
      } finally {
        MiCloudClient.prototype.request = origRequest;
      }
    });
  }

  it("re-checks capability/session gate before batched send and drops disallowed channels", async () => {
    const spec = makeFourOutletSpec();
    const channels = makeFourOutletDevices("101");
    const sleepGate = new SleepGate();
    const batcher = new MiCloudChannelWriteBatcher({ sleep: (ms) => sleepGate.sleep(ms) });
    const sentBatches: MiotPropWrite[][] = [];
    let sessionValid = true;
    const provider = new MiCloudProvider({
      client: {
        setProps: async () => assert.fail("unexpected single setProps"),
        setPropVerdicts: async (writes) => { sentBatches.push([...writes]); return writes.map(() => null); },
        getProps: async () => new Map(),
        action: async () => {},
      },
      specResolver: { resolve: async () => spec },
      deviceForEntity: (id) => channels.find((d) => d.kind.kind === "plug" && d.kind.switchEntityId === id),
      channelBatcher: batcher,
      accountKey: "acc1",
    });

    const promises = channels.map((ch) =>
      provider.execute(
        { kind: "setSwitch", entityId: ch.kind.kind === "plug" ? ch.kind.switchEntityId : "", isOn: false },
        { stillAllowed: () => sessionValid },
      ),
    );
    await waitUntil(() => batcher.pendingCount("101", "acc1") === 4 && sleepGate.waiting === 1, "4 channels queued");
    sessionValid = false;
    sleepGate.release();
    assert.ok((await Promise.allSettled(promises)).every((r) => r.status === "rejected"));
    assert.equal(sentBatches.length, 0);
  });

  it("acknowledgement must identify the exact (did, siid, piid) channel", () => {
    const writes: MiotPropWrite[] = [2, 3, 4].map((siid) => ({ did: "101", siid, piid: 1, value: false }));
    const verdicts = MiCloudClient.propertyVerdicts([
      { did: "101", siid: 3, piid: 1, code: -1 },
      { did: "101", siid: 2, piid: 1, code: 0 },
      { did: "102", siid: 4, piid: 1, code: 0 },
    ], writes);
    assert.equal(verdicts[0], null);
    assert.ok(verdicts[1] instanceof MiCloudError && verdicts[1].kind === "api" && verdicts[1].code === -1);
    assert.ok(verdicts[2] instanceof MiCloudError && verdicts[2].kind === "badResponse");
  });

  it("turns off four channels during read cooldown using the last reserved write token", async () => {
    const session: MiSession = {
      userId: "100", cUserId: "c", ssecurity: "AQIDBA==", serviceToken: "token", passToken: "", region: "cn",
    };
    const accountKey = miAccountId(session);
    const limiter = new MiCloudRateLimiter(() => 0, () => 0, () => 0);
    await limiter.recordLimit(accountKey, "60");
    for (let i = 0; i < 7; i++) {
      assert.equal((await limiter.admit(accountKey, true)).kind, "admitted");
    }
    const requests: MiotPropWrite[][] = [];
    const client = new MiCloudClient(session, async ({ url, body }) => {
      assert.equal(new URL(url).pathname, "/app/miotspec/prop/set");
      const form = new URLSearchParams(body);
      const signedNonce = MiCloudCrypto.signedNonce(session.ssecurity, form.get("_nonce")!);
      const { params } = JSON.parse(MiCloudCrypto.decryptResponse(form.get("data")!, signedNonce)) as {
        params: MiotPropWrite[];
      };
      requests.push(params);
      return {
        status: 200,
        headers: {},
        body: JSON.stringify({ code: 0, result: params.map((write) => ({ ...write, code: 0 })) }),
      };
    }, limiter);
    const did = "101";
    const spec = makeFourOutletSpec();
    const channels = makeFourOutletDevices(did);
    const sleepGate = new SleepGate();
    const batcher = new MiCloudChannelWriteBatcher({ sleep: (ms) => sleepGate.sleep(ms) });
    const provider = new MiCloudProvider({
      client,
      specResolver: { resolve: async () => spec },
      deviceForEntity: (id) => channels.find((device) => device.kind.kind === "plug" && device.kind.switchEntityId === id),
      channelBatcher: batcher,
      accountKey,
    });

    const off = Promise.all(CHANNEL_SIIDS.map((siid) =>
      provider.execute({ kind: "setSwitch", entityId: `miot:${did}:${siid}`, isOn: false }, { userInitiated: true }),
    ));
    await waitUntil(() => batcher.pendingCount(did, accountKey) === 4 && sleepGate.waiting === 1, "4 channels queued");
    sleepGate.release();
    assert.deepEqual(await off, [null, null, null, null]);
    assert.deepEqual(requests, [CHANNEL_SIIDS.map((siid) => ({ did, siid, piid: 1, value: false }))]);
    assert.equal(client.readCooldownMs, 60_000);
    await assert.rejects(() => client.getProps([{ did, siid: 2, piid: 1 }]), { code: 429 });
    await assert.rejects(() => client.setProps([{ did, siid: 2, piid: 1, value: true }]), { code: 429 });
    assert.equal(requests.length, 1);
  });
});
