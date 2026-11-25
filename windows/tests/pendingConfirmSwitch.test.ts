import assert from "node:assert/strict";
import { describe, it, type TestContext } from "node:test";

import { buildDiffPreview } from "../src/core/assistantDiffPreview.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import { buildRoomAutoGroups } from "../src/core/roomAutoGroup.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { confirmPendingDiffPreview } from "../src/ui/roomGroupActions.js";
import { switchHome, switchSource } from "../src/ui/sourceSwitch.js";
import { closeTestWindow, element, mountTestWindow } from "./uiHarness.js";

function light(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomId: "living",
    roomName: "客厅",
    model: "yeelink.light.a",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: `light.${id}`,
      isOn: true,
      brightnessPercent: 80,
      colorTempKelvin: 4000,
      hueDegrees: null,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function plug(id: string, name: string): SmartDevice {
  return {
    id,
    name,
    roomId: "living",
    roomName: "客厅",
    model: "chuangmi.plug.m3",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: `switch.${id}`,
      isOn: false,
      powerWatts: null,
      childLockEntityId: null,
      isChildLocked: false,
    },
  };
}

function armAllPending(app: MenuMijiaWindowsApp): void {
  const device = light("l1", "客厅灯");
  app.pendingDiffPreview = buildDiffPreview({
    intents: [{ targetId: device.id, operation: { kind: "power", isOn: false } }],
    devices: [device],
    scenes: [],
    replyText: "已关闭客厅灯",
    sourceLabel: "本地",
    utterance: "关客厅灯",
    recordHabits: false,
    learnAfterRun: false,
    sourceRevision: app.sourceRevision,
    homeRevision: app.homeRevision,
  });
  const group = buildRoomAutoGroups("living", "客厅", [plug("p1", "插座A"), plug("p2", "插座B")])[0]!;
  app.pendingRoomGroupConfirm = {
    group,
    action: { kind: "toggle" },
    riskyNames: ["插座A", "插座B"],
    sourceRevision: app.sourceRevision,
    homeRevision: app.homeRevision,
  };
  app.pendingSuggestions = [{
    id: "confirm:local",
    title: "确认打开插座A",
    confidencePercent: null,
    intents: [{ targetId: "p1", operation: { kind: "power", isOn: true } }],
  }];
}

/** Mounts a fresh happy-dom window and app, and counts every device write the UI attempts. */
function setup(test: TestContext): { app: MenuMijiaWindowsApp; writes: DeviceCommand[] } {
  const dom = mountTestWindow({ stubInterval: true });
  setLanguage("zh-Hans");
  const app = new MenuMijiaWindowsApp(element<HTMLElement>("#app"));
  test.after(async () => {
    app.dispose();
    await closeTestWindow(dom);
  });
  app.settings.connectionMode = "demo";
  app.settings.interfaceLanguage = "zh-Hans";
  app.settings.blockControlWhileLocked = false;
  const writes: DeviceCommand[] = [];
  app.executeIntents = async (intents) => {
    for (const intent of intents) {
      writes.push({
        kind: "setLightPower",
        entityId: intent.targetId,
        isOn: intent.operation.kind === "power" ? intent.operation.isOn : true,
      });
    }
    return true;
  };
  app.applyCommand = async (command) => { writes.push(command); return true; };
  return { app, writes };
}

describe("pending confirmations cannot survive a home/source switch (§13)", () => {
  it("switchHome clears pendingDiffPreview, pendingRoomGroupConfirm and pendingSuggestions", (test) => {
    const { app } = setup(test);
    armAllPending(app);
    assert.ok(app.pendingDiffPreview && app.pendingRoomGroupConfirm && app.pendingSuggestions.length > 0);

    const homeBefore = app.homeRevision;
    switchHome(app);

    assert.equal(app.pendingDiffPreview, null, "the diff preview must not survive the home switch");
    assert.equal(app.pendingRoomGroupConfirm, null, "the room-group confirmation must not survive the home switch");
    assert.deepEqual(app.pendingSuggestions, [], "suggestions belong to the previous home's context");
    assert.ok(app.homeRevision > homeBefore, "switchHome advances the home level");
  });

  it("switchSource clears pendingDiffPreview, pendingRoomGroupConfirm and pendingSuggestions", (test) => {
    const { app } = setup(test);
    armAllPending(app);

    const sourceBefore = app.sourceRevision;
    switchSource(app, "test-source-switch");

    assert.equal(app.pendingDiffPreview, null, "the diff preview must not survive the source switch");
    assert.equal(app.pendingRoomGroupConfirm, null, "the room-group confirmation must not survive the source switch");
    assert.deepEqual(app.pendingSuggestions, [], "the source switch drops old suggestions");
    assert.ok(app.sourceRevision > sourceBefore, "switchSource advances the source level");
  });
});

describe("stale confirmations after a homeRevision advance refuse to write", () => {
  it("confirmPendingDiffPreview refuses a preview armed for an older home", async (test) => {
    const { app, writes } = setup(test);
    armAllPending(app);
    const preview = app.pendingDiffPreview!;
    assert.equal(preview.sourceRevision, app.sourceRevision);
    assert.equal(preview.homeRevision, app.homeRevision);

    // A home switch happens elsewhere (e.g. the selection/save path) without going through the
    // diff-preview clearing site; the confirmation itself must still fail closed.
    app.sourceEpoch.advance("home");

    const confirmed = await confirmPendingDiffPreview(app);
    assert.equal(confirmed, false, "confirming a stale diff preview must be refused");
    assert.deepEqual(writes, [], "no device writes may be issued for the previous home");
    assert.equal(app.pendingDiffPreview, null, "the stale card must be dismissed");
  });

  it("the room-group confirm button refuses a confirmation armed for an older home", (test) => {
    const { app, writes } = setup(test);
    armAllPending(app);
    const pending = app.pendingRoomGroupConfirm!;
    assert.equal(pending.sourceRevision, app.sourceRevision);
    assert.equal(pending.homeRevision, app.homeRevision);

    app.selectRoom("living", "客厅");
    app.sourceEpoch.advance("home");
    app.render();

    const confirmButton = element<HTMLButtonElement>("#btn-room-group-confirm");
    confirmButton.click();

    assert.deepEqual(writes, [], "clicking a stale room-group confirmation must not write devices");
    assert.equal(app.pendingRoomGroupConfirm, null, "the stale card must be dismissed");
  });
});
