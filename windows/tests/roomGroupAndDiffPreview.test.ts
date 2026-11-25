import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildDiffPreview, requiresDiffPreview } from "../src/core/assistantDiffPreview.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, DeviceIntent, SmartDevice } from "../src/core/models.js";
import { lockOptimistic, mergeHomeSnapshotRespectingLocks } from "../src/core/optimisticLock.js";
import {
  buildRoomAutoGroups,
  circularHueMean,
  GROUP_COVER_IGNORE_WINDOW_MS,
} from "../src/core/roomAutoGroup.js";
import { cancelPendingDiffPreview, confirmPendingDiffPreview, executeRoomGroupAction } from "../src/ui/roomGroupActions.js";

function light(id: string, name: string, isOn: boolean, brightness: number, hueDegrees?: number, roomId = "living"): SmartDevice {
  return {
    id,
    name,
    roomId,
    roomName: roomId === "living" ? "客厅" : "书房",
    model: "yeelink.light.ceiling",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: `light.${id}`,
      isOn,
      brightnessPercent: brightness,
      colorTempKelvin: 4000,
      hueDegrees: hueDegrees ?? null,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function plug(id: string, name: string, isOn: boolean, roomId = "living"): SmartDevice {
  return {
    id,
    name,
    roomId,
    roomName: roomId === "living" ? "客厅" : "书房",
    model: "chuangmi.plug.m3",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn,
      powerWatts: null,
      childLockEntityId: null,
      isChildLocked: false,
    },
  };
}

function cover(id: string, positionPercent: number, motion: "stopped" | "opening" | "closing" = "stopped"): SmartDevice {
  return {
    id,
    name: id,
    roomId: "living",
    roomName: "客厅",
    model: "lumi.curtain.v1",
    isOnline: true,
    kind: {
      kind: "cover",
      entityId: `cover.${id}`,
      subtype: "curtain",
      positionPercent,
      positionWritable: true,
      openDescription: "open",
      closeDescription: "close",
      pauseDescription: "pause",
      batteryPercent: null,
      faultText: null,
      motion,
    },
  };
}

describe("Room auto-group aggregation & 60 s cover ignore window", () => {
  it("computes circular hue mean across 350°/10° and groups >= 2 same-kind room devices", () => {
    const wrapped = circularHueMean([350, 10]);
    assert.ok(wrapped !== null && (wrapped < 0.001 || Math.abs(wrapped - 360) < 0.001));
    assert.ok(Math.abs((circularHueMean([60, 120]) ?? 0) - 90) < 0.001);
    assert.equal(circularHueMean([]), null);
    assert.equal(circularHueMean([0, 180]), null);

    const devices = [
      light("l1", "客厅主灯", true, 80, 350),
      light("l2", "客厅射灯", true, 40, 10),
      light("l3", "客厅灯带", false, 10, 180),
      plug("p1", "客厅插座", false),
    ];
    setLanguage("zh-Hans");
    const groups = buildRoomAutoGroups("living", "客厅", devices);
    assert.equal(groups.length, 1);
    const group = groups[0]!;
    assert.equal(group.kind, "light");
    assert.equal(group.count, 3);
    assert.equal(group.isAnyOn, true);
    assert.equal(group.activeCount, 2);
    assert.equal(group.averageBrightness, 60);
    assert.ok(group.averageHueDegrees !== null && group.averageHueDegrees < 0.001);
    assert.equal(group.label, "客厅 3 盏灯");
  });

  it("ignores intermediate cover movement reports for 60 s after a group cover command", () => {
    const t0 = 100_000;
    const localCover = cover("c1", 100, "opening");
    const host = { sourceRevision: 1, devices: [localCover] };
    lockOptimistic(host, "c1", GROUP_COVER_IGNORE_WINDOW_MS, {
      nowMs: t0,
      coverOriginPosition: 0,
      ignoreCoverMovement: true,
    });

    // At t + 30 s, intermediate position 45% is ignored.
    const mid = mergeHomeSnapshotRespectingLocks(host, [cover("c1", 45, "opening")], undefined, t0 + 30_000).devices;
    const midDev = mid[0]!;
    assert.equal(midDev.kind.kind === "cover" ? midDev.kind.positionPercent : null, 100);

    // At t + 61 s, snapshot position 90% is adopted.
    const settled = mergeHomeSnapshotRespectingLocks(host, [cover("c1", 90, "stopped")], undefined, t0 + 61_000).devices;
    const settledDev = settled[0]!;
    assert.equal(settledDev.kind.kind === "cover" ? settledDev.kind.positionPercent : null, 90);
  });
});

describe("Room group write gates & inline diff preview thresholds", () => {
  it("gates diff preview at >= 2 devices or high-risk, runs single low-risk directly, and sends nothing on cancel", async () => {
    const l1 = light("l1", "客厅主灯", true, 80);
    const l2 = light("l2", "客厅射灯", true, 60);
    const p1 = plug("p1", "书房插座", false, "study");
    const devices = [l1, l2, p1];

    const singleLowRisk: DeviceIntent[] = [{ targetId: "l1", operation: { kind: "power", isOn: false } }];
    const multiDevice: DeviceIntent[] = [
      { targetId: "l1", operation: { kind: "power", isOn: false } },
      { targetId: "l2", operation: { kind: "power", isOn: false } },
    ];
    const singleHighRisk: DeviceIntent[] = [{ targetId: "p1", operation: { kind: "power", isOn: true } }];

    assert.equal(requiresDiffPreview(singleLowRisk, devices), false);
    assert.equal(requiresDiffPreview(multiDevice, devices), true);
    assert.equal(requiresDiffPreview(singleHighRisk, devices), true);

    const preview = buildDiffPreview({
      intents: multiDevice,
      devices,
      scenes: [],
      replyText: "已关闭客厅灯",
      sourceLabel: "本地",
      utterance: "关客厅灯",
      recordHabits: true,
      learnAfterRun: false,
      sourceRevision: 1,
    });
    assert.equal(preview.items.length, 2);
    assert.equal(preview.hasHighRiskDevice, false);

    const sent: DeviceCommand[] = [];
    const fakeHost = {
      sourceRevision: 1,
      devices,
      scenes: [],
      settings: { connectionMode: "demo", blockControlWhileLocked: false, interfaceLanguage: "zh-Hans" },
      layout: { aliases: {} },
      pendingDiffPreview: preview,
      pendingRoomGroupConfirm: null,
      replyBanner: null,
      render: () => {},
      executeIntents: async (intents: readonly DeviceIntent[]) => {
        for (const i of intents) sent.push({ kind: "setLightPower", entityId: i.targetId, isOn: false });
        return true;
      },
      applyCommand: async (cmd: DeviceCommand) => { sent.push(cmd); return true; },
    } as unknown as Parameters<typeof cancelPendingDiffPreview>[0];

    cancelPendingDiffPreview(fakeHost);
    assert.equal(fakeHost.pendingDiffPreview, null);
    assert.equal(sent.length, 0);

    fakeHost.pendingDiffPreview = preview;
    const confirmed = await confirmPendingDiffPreview(fakeHost);
    assert.equal(confirmed, true);
    assert.equal(sent.length, 2);

    // High-risk room group requires one batch confirmation before sending.
    const plugGroup = buildRoomAutoGroups("living", "客厅", [plug("p2", "插座A", false), plug("p3", "插座B", false)])[0]!;
    fakeHost.devices = [plug("p2", "插座A", false), plug("p3", "插座B", false)];
    const armed = await executeRoomGroupAction(fakeHost, plugGroup, { kind: "toggle" }, false);
    assert.equal(armed, false);
    assert.ok(fakeHost.pendingRoomGroupConfirm !== null);
    assert.equal(fakeHost.pendingRoomGroupConfirm.riskyNames.length, 2);
    assert.equal(sent.length, 2);
  });
});
