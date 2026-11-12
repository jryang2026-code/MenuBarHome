import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { assertMissing } from "./dom.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { homeAssistantIdentity } from "../src/core/homeAssistant.js";
import type { FacetControl, SmartDevice } from "../src/core/models.js";

let dom: Window;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  assert.ok(found, `Missing control ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function makeFacet(overrides: Partial<FacetControl> & Pick<FacetControl, "id" | "name">): FacetControl {
  const serviceId = Number(overrides.id.split(".")[0]) || 2;
  const propPart = overrides.id.split(".")[1] ?? "1";
  const isAction = propPart.startsWith("a");
  const itemIid = Number(isAction ? propPart.slice(1) : propPart) || 1;
  return {
    id: overrides.id,
    kind: overrides.kind ?? "toggle",
    serviceName: overrides.serviceName ?? "setting",
    name: overrides.name,
    title: overrides.title ?? null,
    value: overrides.value ?? false,
    unit: overrides.unit ?? null,
    scale: overrides.scale ?? null,
    range: overrides.range ?? null,
    options: overrides.options ?? [],
    isWritable: overrides.isWritable ?? true,
    writesByDefault: overrides.writesByDefault ?? false,
    isHighValue: overrides.isHighValue ?? false,
    target:
      overrides.target !== undefined
        ? overrides.target
        : isAction
          ? { kind: "action", entityId: `miot:dev:${serviceId}:${itemIid}` }
          : { kind: "property", entityId: `miot:dev:${serviceId}`, piid: itemIid },
    ...(overrides.arguments ? { arguments: overrides.arguments } : {}),
    ...(overrides.portionArgumentIndex !== undefined
      ? { portionArgumentIndex: overrides.portionArgumentIndex }
      : {}),
    ...(overrides.fedToday !== undefined ? { fedToday: overrides.fedToday } : {}),
    ...(overrides.isConfirmedWrite !== undefined
      ? { isConfirmedWrite: overrides.isConfirmedWrite }
      : {}),
  };
}

interface MountedHA {
  readonly app: MenuMijiaWindowsApp;
  readonly serviceCalls: Array<{ domain: string; service: string; entity_id: string; data: Record<string, unknown> }>;
}

async function mountWithHADevices(
  devices: SmartDevice[],
  extraSettings: Record<string, unknown> = {},
): Promise<MountedHA> {
  const haBaseURL = "https://ha.example.test";
  const haToken = "test-ha-token";
  const serviceCalls: Array<{ domain: string; service: string; entity_id: string; data: Record<string, unknown> }> = [];
  const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    if (command === "ha_execute") {
      const call = args.command as { domain: string; service: string; entity_id: string; data: Record<string, unknown> };
      serviceCalls.push(call);
      return null;
    }
    if (command === "ha_snapshot") {
      return { areas: [], devices: [], entities: [], states: [] };
    }
    return undefined;
  };
  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  localStorage.setItem(
    "menumijia.windows.settings.v2",
    JSON.stringify({
      connectionMode: "homeAssistant",
      hasCompletedOnboarding: true,
      haBaseURL,
      cachedHAHome: {
        identity: homeAssistantIdentity(haBaseURL, haToken),
        home: { devices, scenes: [], environmentReadings: [] },
      },
      ...extraSettings,
    }),
  );
  const app = new MenuMijiaWindowsApp(element("#app"));
  app.refreshDevices = async () => {};
  app.refreshHADevices = async () => {};
  await setImmediate();
  await setImmediate();
  app.settings.haToken = haToken;
  app.devices = structuredClone(devices);
  app.render();
  await setImmediate();
  return { app, serviceCalls };
}

beforeEach(() => {
  dom = mountTestWindow();
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("Cover, Plug, Generic, and Climate Swing Detail Drawers", () => {
  it("never offers an empty detail drawer for bare plug, bare cover, or bare generic cards", async () => {
    const bareDevices: SmartDevice[] = [
      {
        id: "bare_plug",
        name: "墙壁插座",
        roomId: "living",
        roomName: "客厅",
        model: "chuangmi.plug.v1",
        isOnline: true,
        kind: {
          kind: "plug",
          switchEntityId: "switch.wall_plug",
          isOn: false,
          powerWatts: null,
          energyKwh: null,
          childLockEntityId: null,
          isChildLocked: false,
        },
      },
      {
        id: "bare_cover",
        name: "只读卷帘",
        roomId: "living",
        roomName: "客厅",
        model: "cover.ro",
        isOnline: true,
        kind: {
          kind: "cover",
          entityId: "cover.ro",
          subtype: "curtain",
          positionPercent: 50,
          positionWritable: false,
          openDescription: null,
          closeDescription: null,
          pauseDescription: null,
          batteryPercent: null,
          faultText: null,
          motion: "stopped",
        },
      },
      {
        id: "bare_generic",
        name: "鱼缸只读卡",
        roomId: "living",
        roomName: "客厅",
        model: "xiaomi.fishtank.v1",
        isOnline: true,
        kind: {
          kind: "generic",
          deviceType: "fish-tank",
          typeTitle: "鱼缸",
          isOn: false,
          powerControl: null,
          isReadOnly: true,
          readouts: ["水温 25°C"],
          alerts: [],
          symbolName: null,
        },
      },
    ];

    const { app } = await mountWithHADevices(bareDevices);
    assertMissing(document.querySelector('[data-expand-device="bare_plug"]'));
    assertMissing(document.querySelector('[data-expand-device="bare_cover"]'));
    assertMissing(document.querySelector('[data-expand-device="bare_generic"]'));

    // Clicking the bare plug card body asks to toggle power instead of expanding an empty drawer.
    await click('[data-body-device="bare_plug"]');
    assert.equal(app.expandedDeviceId, null);
    assert.match(app.replyBanner?.text ?? "", /墙壁插座/);
  });

  it("renders cover position slider, open/stop/close, battery, and enforces all 4 cover risk subtypes + unknown fallback", async () => {
    const makeCover = (
      id: string,
      name: string,
      subtype: Extract<SmartDevice["kind"], { kind: "cover" }>["subtype"],
    ): SmartDevice => ({
      id,
      name,
      roomId: "living",
      roomName: "客厅",
      model: "lumi.curtain.v1",
      isOnline: true,
      kind: {
        kind: "cover",
        entityId: `cover.${id}`,
        subtype,
        positionPercent: 40,
        positionWritable: true,
        openDescription: "Open",
        closeDescription: "Close",
        pauseDescription: "Pause",
        batteryPercent: 86,
        faultText: null,
        motion: "stopped",
      },
    });

    const unknownCover = makeCover("unknown_act", "未知执行器", "curtain");
    (unknownCover.kind as { subtype: unknown }).subtype = "unknown-custom";

    const { app, serviceCalls } = await mountWithHADevices([
      makeCover("curtain_1", "客厅窗帘", "curtain"),
      makeCover("window_1", "阳台推窗器", "window-opener"),
      makeCover("garage_1", "车库门", "garage-door"),
      unknownCover,
    ]);

    // 1. Curtain: direct open, stop, close, and position slider write.
    await click('[data-expand-device="curtain_1"]');
    assert.match(element('[data-tile-id="curtain_1"]').textContent ?? "", /电量 86%/);
    await click('[data-covermotor="curtain_1|open|Open"]');
    assert.equal(serviceCalls.length, 1);
    assert.equal(serviceCalls[0]?.service, "open_cover");

    await click('[data-covermotor="curtain_1|stop|Pause"]');
    assert.equal(serviceCalls.length, 2);
    assert.equal(serviceCalls[1]?.service, "stop_cover");

    await click('[data-covermotor="curtain_1|close|Close"]');
    assert.equal(serviceCalls.length, 3);
    assert.equal(serviceCalls[2]?.service, "close_cover");

    const slider = element<HTMLInputElement>('[data-coverpos="curtain_1"]');
    slider.value = "72";
    slider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    await setImmediate();
    assert.equal(serviceCalls.length, 4);
    assert.deepEqual(serviceCalls[3], {
      domain: "cover",
      service: "set_cover_position",
      entity_id: "cover.curtain_1",
      data: { position: 72 },
    });

    // 2. Window opener: Open confirms, Close is direct, Stop never asks.
    await click('[data-expand-device="window_1"]');
    await click('[data-covermotor="window_1|open|Open"]');
    assert.equal(serviceCalls.length, 4, "first open tap arms confirmation");
    assert.match(app.replyBanner?.text ?? "", /再点一次确认执行/);
    await click('[data-covermotor="window_1|open|Open"]');
    assert.equal(serviceCalls.length, 5, "second open tap executes");
    assert.equal(serviceCalls[4]?.service, "open_cover");

    await click('[data-covermotor="window_1|close|Close"]');
    assert.equal(serviceCalls.length, 6, "window opener close is direct");
    assert.equal(serviceCalls[5]?.service, "close_cover");

    // 3. Garage door: BOTH Open and Close confirm; Stop is direct.
    await click('[data-expand-device="garage_1"]');
    await click('[data-covermotor="garage_1|open|Open"]');
    assert.equal(serviceCalls.length, 6, "garage open arms confirmation");
    await click('[data-covermotor="garage_1|open|Open"]');
    assert.equal(serviceCalls.length, 7);
    assert.equal(serviceCalls[6]?.service, "open_cover");

    await click('[data-covermotor="garage_1|stop|Pause"]');
    assert.equal(serviceCalls.length, 8, "garage stop never confirms");
    assert.equal(serviceCalls[7]?.service, "stop_cover");

    await click('[data-covermotor="garage_1|close|Close"]');
    assert.equal(serviceCalls.length, 8, "garage close arms confirmation");
    await click('[data-covermotor="garage_1|close|Close"]');
    assert.equal(serviceCalls.length, 9);
    assert.equal(serviceCalls[8]?.service, "close_cover");

    // 4. Unknown subtype: treated as windowOpener (Open confirms, Close is direct).
    await click('[data-expand-device="unknown_act"]');
    await click('[data-covermotor="unknown_act|open|Open"]');
    assert.equal(serviceCalls.length, 9, "unknown cover open arms confirmation");
    await click('[data-covermotor="unknown_act|open|Open"]');
    assert.equal(serviceCalls.length, 10);
    await click('[data-covermotor="unknown_act|close|Close"]');
    assert.equal(serviceCalls.length, 11, "unknown cover close is direct");
  });

  it("renders plug live W / kWh metrics and child-lock toggle end-to-end", async () => {
    const { serviceCalls } = await mountWithHADevices([
      {
        id: "desk_plug",
        name: "书桌插座",
        roomId: "study",
        roomName: "书房",
        model: "cuco.plug.cp2",
        isOnline: true,
        kind: {
          kind: "plug",
          switchEntityId: "switch.desk_plug",
          isOn: true,
          powerWatts: 135,
          energyKwh: 2.48,
          childLockEntityId: "switch.desk_plug_lock",
          isChildLocked: false,
        },
      },
    ]);

    await click('[data-expand-device="desk_plug"]');
    const drawerText = element('[data-tile-id="desk_plug"] .cc-tile-drawer').textContent ?? "";
    assert.match(drawerText, /135 W/);
    assert.match(drawerText, /2\.48 kWh/);
    assert.match(drawerText, /按键锁：关/);

    await click('[data-pluglock="desk_plug"]');
    await setImmediate();
    assert.deepEqual(serviceCalls[0], {
      domain: "switch",
      service: "turn_on",
      entity_id: "switch.desk_plug_lock",
      data: {},
    });
    assert.match(element('[data-pluglock="desk_plug"]').textContent ?? "", /按键锁：开/);
  });

  it("renders climate swingMode pills and dispatches climate.set_swing_mode end-to-end", async () => {
    const { app, serviceCalls } = await mountWithHADevices([
      {
        id: "living_ac",
        name: "客厅空调",
        roomId: "living",
        roomName: "客厅",
        model: "xiaomi.aircondition.mc5",
        isOnline: true,
        kind: {
          kind: "climate",
          entityId: "climate.living_ac",
          isOn: true,
          hvacMode: "cool",
          availableModes: ["off", "cool", "heat"],
          targetTemperature: 24,
          currentTemperature: 27,
          minTemp: 16,
          maxTemp: 30,
          step: 1,
          fanMode: "auto",
          availableFanModes: ["auto", "high"],
          swingMode: "off",
          availableSwingModes: ["off", "vertical", "horizontal"],
        },
      },
    ]);

    await click('[data-expand-device="living_ac"]');
    const verticalBtn = element('[data-acswing="living_ac:vertical"]');
    assert.match(verticalBtn.textContent ?? "", /上下扫风/);

    await click('[data-acswing="living_ac:vertical"]');
    await setImmediate();
    assert.deepEqual(serviceCalls[0], {
      domain: "climate",
      service: "set_swing_mode",
      entity_id: "climate.living_ac",
      data: { swing_mode: "vertical" },
    });
    assert.equal(element('[data-acswing="living_ac:vertical"]').getAttribute("aria-pressed"), "true");
    assert.ok(app.lastUndoAction);
  });

  it("renders generic red alert banner and jumps to & expands MoreSettings including secondary fold", async () => {
    const genericDevice: SmartDevice = {
      id: "fish_tank",
      name: "智能鱼缸",
      roomId: "living",
      roomName: "客厅",
      model: "xiaomi.fishtank.v1",
      isOnline: true,
      kind: {
        kind: "generic",
        deviceType: "fish-tank",
        typeTitle: "鱼缸",
        isOn: true,
        powerControl: null,
        isReadOnly: false,
        readouts: ["水温 25.4°C"],
        alerts: ["水泵状态：堵塞"],
        symbolName: null,
      },
    };
    const facets: FacetControl[] = [
      makeFacet({
        id: "2.4",
        kind: "reading",
        serviceName: "fish-tank",
        name: "water-pump-status",
        value: 4,
        options: [{ value: 4, label: "Blocked" }],
        isWritable: false,
        target: null,
      }),
      ...Array.from({ length: 6 }, (_, i) =>
        makeFacet({
          id: `3.${i + 1}`,
          kind: "toggle",
          serviceName: "light",
          name: `aux-${i + 1}`,
          title: `辅助项 ${i + 1}`,
          writesByDefault: true,
        }),
      ),
      makeFacet({
        id: "2.9",
        kind: "toggle",
        serviceName: "fish-tank",
        name: "water-pump",
        value: true,
        writesByDefault: false,
      }),
    ];

    const { app } = await mountWithHADevices([genericDevice]);
    app.deviceFacets = { fish_tank: facets };
    app.render();
    await setImmediate();

    await click('[data-expand-device="fish_tank"]');
    const alertBanner = element('[data-tile-id="fish_tank"] .cc-generic-alert');
    assert.match(alertBanner.textContent ?? "", /水泵状态：堵塞/);

    // MoreSettings starts collapsed and secondary overflow row 2.9 is omitted from DOM.
    assert.equal(element('[data-more-settings-toggle="fish_tank"]').getAttribute("aria-expanded"), "false");
    assert.equal(element('[data-tile-id="fish_tank"] .cc-facet-body').hasAttribute("hidden"), true);
    assertMissing(document.querySelector("#facet-row-fish_tank-2_9"));

    // Clicking 去处理 expands MoreSettings + secondary overflow and reveals the target row!
    await click('[data-facet-reveal="fish_tank|2.9"]');
    assert.equal(element('[data-more-settings-toggle="fish_tank"]').getAttribute("aria-expanded"), "true");
    assert.equal(element('[data-tile-id="fish_tank"] .cc-facet-body').hasAttribute("hidden"), false);
    const revealedRow = element("#facet-row-fish_tank-2_9");
    assert.ok(revealedRow.classList.contains("is-revealed"));
  });
});

describe("FeedAction, MoreSettings 2-Stage Folding, and Live Slider Readouts", () => {
  it("executes parameterized FeedAction with portion selector and fedToday confirmation, exempt from allowAdvancedFacetWrites and without undo banner", async () => {
    const dispatched: Array<{ command: unknown }> = [];
    const feeder: SmartDevice = {
      id: "pet_feeder",
      name: "智能喂食器",
      roomId: "living",
      roomName: "客厅",
      model: "mmgg.feeder.inland",
      isOnline: true,
      kind: {
        kind: "generic",
        deviceType: "pet-feeder",
        typeTitle: "宠物喂食器",
        isOn: true,
        powerControl: null,
        isReadOnly: false,
        readouts: [],
        alerts: [],
        symbolName: null,
      },
    };
    const feedFacet = makeFacet({
      id: "2.a1",
      kind: "button",
      serviceName: "pet-feeder",
      name: "pet-food-out",
      title: "出粮",
      isWritable: true,
      writesByDefault: false,
      isConfirmedWrite: true,
      isHighValue: true,
      arguments: [{ propertyId: 1, name: "feeding-measure", format: "uint8", range: { min: 1, max: 5, step: 1 } }],
      portionArgumentIndex: 0,
      fedToday: "2 份",
      target: { kind: "action", entityId: "miot-action:pet_feeder:2:1" },
    });
    const lockedFacet = makeFacet({
      id: "2.6",
      kind: "toggle",
      serviceName: "pet-feeder",
      name: "desiccant-reset",
      title: "干燥剂复位",
      isWritable: true,
      writesByDefault: false,
    });

    const { app } = await mountWithHADevices([feeder], { allowAdvancedFacetWrites: false });
    app.deviceFacets = { pet_feeder: [feedFacet, lockedFacet] };
    app.applyCommand = async (command) => {
      dispatched.push({ command });
      return true;
    };
    app.render();
    await setImmediate();

    await click('[data-expand-device="pet_feeder"]');
    await click('[data-more-settings-toggle="pet_feeder"]');

    // FeedAction is enabled despite allowAdvancedFacetWrites=false, while lockedFacet is disabled.
    const actionBtn = element<HTMLButtonElement>('[data-facet-action="pet_feeder|2.a1"]');
    const portionSelect = element<HTMLSelectElement>('[data-facet-portion="pet_feeder|2.a1"]');
    const lockedBtn = element<HTMLButtonElement>('[data-facet-toggle="pet_feeder|2.6"]');
    assert.equal(actionBtn.disabled, false);
    assert.equal(portionSelect.disabled, false);
    assert.equal(lockedBtn.disabled, true);
    assert.match(element('[data-tile-id="pet_feeder"] .cc-facet-section').textContent ?? "", /今日已投喂 2 份/);

    // Select 3 portions and tap once -> confirmation copy includes 3 份 and 今日已投喂 2 份.
    portionSelect.value = "3";
    portionSelect.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();

    await click('[data-facet-action="pet_feeder|2.a1"]');
    assert.equal(dispatched.length, 0);
    assert.match(app.replyBanner?.text ?? "", /3 份/);
    assert.match(app.replyBanner?.text ?? "", /今日已投喂 2 份/);

    // Changing portion to 4 re-arms instead of spending the 3-portion confirmation.
    const updatedSelect = element<HTMLSelectElement>('[data-facet-portion="pet_feeder|2.a1"]');
    updatedSelect.value = "4";
    updatedSelect.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();

    await click('[data-facet-action="pet_feeder|2.a1"]');
    assert.equal(dispatched.length, 0, "changing portion re-arms confirmation");
    assert.match(app.replyBanner?.text ?? "", /4 份/);

    // Second tap confirms and dispatches arguments: [4] with NO undo banner!
    await click('[data-facet-action="pet_feeder|2.a1"]');
    await setImmediate();
    assert.equal(dispatched.length, 1);
    assert.deepEqual(dispatched[0]?.command, {
      kind: "pressButton",
      entityId: "miot-action:pet_feeder:2:1",
      arguments: [4],
    });
    assert.equal(app.lastUndoAction, null, "feeding must not offer an undo banner");
    assertMissing(document.querySelector("#btn-undo"));
  });

  it("folds >6 secondary facets, disambiguates duplicate titles, links to Settings, and resets on close/blur/backend switch (§13)", async () => {
    const devA: SmartDevice = {
      id: "purifier_1",
      name: "客厅净化器",
      roomId: "living",
      roomName: "客厅",
      model: "zhimi.airp.v1",
      isOnline: true,
      kind: {
        kind: "generic",
        deviceType: "air-purifier",
        typeTitle: "净化器",
        isOn: true,
        powerControl: null,
        isReadOnly: false,
        readouts: [],
        alerts: [],
        symbolName: null,
      },
    };
    const devB: SmartDevice = {
      ...devA,
      id: "study_dev",
      name: "书房新风",
      roomId: "study",
      roomName: "书房",
    };

    const facets: FacetControl[] = [
      makeFacet({ id: "2.1", kind: "toggle", serviceName: "fan-control", name: "mode", title: "模式", writesByDefault: true }),
      makeFacet({ id: "3.1", kind: "toggle", serviceName: "fresh-air", name: "mode", title: "模式", writesByDefault: true }),
      makeFacet({ id: "4.1", kind: "toggle", serviceName: "setting", name: "child-lock", title: "童锁", writesByDefault: false }),
      makeFacet({ id: "4.2", kind: "toggle", serviceName: "setting", name: "led", title: "指示灯", writesByDefault: true }),
      makeFacet({ id: "4.3", kind: "toggle", serviceName: "setting", name: "buzzer", title: "提示音", writesByDefault: true }),
      makeFacet({ id: "4.4", kind: "toggle", serviceName: "setting", name: "anion", title: "负离子", writesByDefault: true }),
      makeFacet({ id: "4.5", kind: "toggle", serviceName: "setting", name: "uv", title: "紫外线", writesByDefault: false }),
      makeFacet({ id: "5.1", kind: "toggle", serviceName: "air-purifier", name: "brightness", title: "屏幕亮度", writesByDefault: true, isHighValue: true }),
    ];

    const { app } = await mountWithHADevices([devA, devB]);
    app.deviceFacets = { purifier_1: facets };
    app.render();
    await setImmediate();

    await click('[data-expand-device="purifier_1"]');

    // Collapsed by default
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "false");
    assert.equal(element('[data-tile-id="purifier_1"] .cc-facet-body').hasAttribute("hidden"), true);

    // Stage 1 expand: high-value facet (5.1) comes first, duplicate "模式" labels carry service suffix,
    // and 2 overflow items (>6 of 8) stay folded behind "还有 2 项次要设置".
    await click('[data-more-settings-toggle="purifier_1"]');
    const body = element('[data-tile-id="purifier_1"] .cc-facet-body');
    assert.equal(body.hasAttribute("hidden"), false);
    const firstStageRows = Array.from(body.querySelectorAll(".cc-facet-row")).map((el) => el.id);
    assert.equal(firstStageRows.length, 6);
    assert.equal(firstStageRows[0], "facet-row-purifier_1-5_1", "highlighted facet renders first");
    assert.match(body.textContent ?? "", /模式 · 风扇/);
    assert.match(body.textContent ?? "", /模式 · 新风/);
    assert.match(element('[data-more-settings-rest="purifier_1"]').textContent ?? "", /还有 2 项次要设置/);
    assertMissing(document.querySelector("#facet-row-purifier_1-4_4"));
    assertMissing(document.querySelector("#facet-row-purifier_1-4_5"));

    // Stage 2 expand reveals all 8 rows and persists across re-render while drawer stays open.
    await click('[data-more-settings-rest="purifier_1"]');
    assert.equal(element('[data-tile-id="purifier_1"] .cc-facet-body').querySelectorAll(".cc-facet-row").length, 8);
    app.render();
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "true");
    assert.equal(element('[data-tile-id="purifier_1"] .cc-facet-body').querySelectorAll(".cc-facet-row").length, 8);

    // Closing and reopening the drawer resets MoreSettings to collapsed.
    await click('[data-expand-device="purifier_1"]');
    await click('[data-expand-device="purifier_1"]');
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "false");
    assert.equal(element('[data-tile-id="purifier_1"] .cc-facet-body').hasAttribute("hidden"), true);

    // Backend sourceRevision change resets MoreSettings.
    await click('[data-more-settings-toggle="purifier_1"]');
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "true");
    app.invalidateSourceControl();
    app.render();
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "false");

    // Window blur resets MoreSettings.
    await click('[data-more-settings-toggle="purifier_1"]');
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "true");
    window.dispatchEvent(new Event("blur"));
    app.render();
    assert.equal(element('[data-more-settings-toggle="purifier_1"]').getAttribute("aria-expanded"), "false");

    // Locked-control notice links directly to the System settings tab with #settings-allow-advanced-facets.
    await click('[data-more-settings-toggle="purifier_1"]');
    await click('[data-open-facet-settings="purifier_1"]');
    assert.equal(app.activeSheet, "settings");
    assert.equal(app.settingsTab, "system");
    assert.equal(
      element('[data-settings-panel="system"]').hasAttribute("hidden"),
      false,
    );
  });

  it("updates slider labels (%, K, °C, facet value) live on input while deferring queueBackgroundRender until change", async () => {
    const light: SmartDevice = {
      id: "study_lamp",
      name: "书房台灯",
      roomId: "study",
      roomName: "书房",
      model: "yeelink.light.lamp4",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "light.study_lamp",
        isOn: true,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    };
    const ac: SmartDevice = {
      id: "study_ac",
      name: "书房空调",
      roomId: "study",
      roomName: "书房",
      model: "xiaomi.ac.v1",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "climate.study_ac",
        isOn: true,
        hvacMode: "cool",
        availableModes: ["off", "cool"],
        targetTemperature: 26,
        currentTemperature: 28,
        minTemp: 16,
        maxTemp: 30,
        step: 0.5,
        fanMode: null,
        availableFanModes: [],
      },
    };

    const { app, serviceCalls } = await mountWithHADevices([light, ac], { climatePanel: false });
    app.deviceFacets = {
      study_lamp: [
        makeFacet({
          id: "2.7",
          kind: "slider",
          serviceName: "light",
          name: "delay-off",
          title: "延时关灯",
          value: 10,
          unit: "minutes",
          range: { min: 1, max: 60, step: 1 },
          writesByDefault: true,
        }),
      ],
    };
    app.render();
    await setImmediate();

    await click('[data-expand-device="study_lamp"]');
    await click('[data-more-settings-toggle="study_lamp"]');

    const briSlider = element<HTMLInputElement>('[data-brightness="study_lamp"]');
    const ctSlider = element<HTMLInputElement>('[data-colortemp="study_lamp"]');
    const facetSlider = element<HTMLInputElement>('[data-facet-number="study_lamp|2.7"]');

    // Drag brightness on input -> live % updates, zero network calls, and queueBackgroundRender defers!
    briSlider.value = "83";
    briSlider.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(
      briSlider.closest(".cc-slider-group")?.querySelector(".cc-slider-label strong")?.textContent,
      "83%",
    );
    assert.equal(serviceCalls.length, 0, "input must not dispatch network writes");

    app.queueBackgroundRender();
    assert.equal(app.pendingCloudRender, true, "background render defers while slider drag is active");
    assert.equal(
      element<HTMLInputElement>('[data-brightness="study_lamp"]').value,
      "83",
      "DOM was not rebuilt underneath the active slider drag",
    );

    // Drag colorTemp (K) and facet slider on input -> live K and formatted facet value update.
    ctSlider.value = "5200";
    ctSlider.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(
      ctSlider.closest(".cc-slider-group")?.querySelector(".cc-slider-label strong")?.textContent,
      "5200K",
    );

    facetSlider.value = "25";
    facetSlider.dispatchEvent(new Event("input", { bubbles: true }));
    assert.match(
      facetSlider.closest(".cc-facet-row")?.querySelector(".cc-facet-value")?.textContent ?? "",
      /25/,
    );
    assert.equal(serviceCalls.length, 0);

    // Releasing brightness on change dispatches network call and clears pointerIsDown.
    briSlider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(app.pointerIsDown, false);
    assert.equal(serviceCalls.length, 1);
    assert.deepEqual(serviceCalls[0], {
      domain: "light",
      service: "turn_on",
      entity_id: "light.study_lamp",
      data: { brightness_pct: 83 },
    });

    // Climate °C slider live readout on input vs change.
    await click('[data-expand-device="study_ac"]');
    const tempSlider = element<HTMLInputElement>('[data-actemp="study_ac"]');
    tempSlider.value = "22.5";
    tempSlider.dispatchEvent(new Event("input", { bubbles: true }));
    assert.match(
      tempSlider.closest(".cc-slider-group")?.querySelector(".cc-slider-label strong")?.textContent ?? "",
      /22\.5°C/,
    );
    assert.equal(serviceCalls.length, 1, "climate slider input does not dispatch");
    tempSlider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(serviceCalls.length, 2);
  });

  it("reverts plug child-lock, cover position, and climate swingMode UI state on Undo", async () => {
    const plug: SmartDevice = {
      id: "undo_plug",
      name: "书桌插座",
      roomId: "study",
      roomName: "书房",
      model: "cuco.plug.cp1",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "switch.undo_plug",
        isOn: true,
        powerWatts: 18,
        energyKwh: null,
        childLockEntityId: "switch.undo_plug_lock",
        isChildLocked: false,
      },
    };
    const curtain: SmartDevice = {
      id: "undo_curtain",
      name: "卧室窗帘",
      roomId: "study",
      roomName: "书房",
      model: "lumi.curtain.v1",
      isOnline: true,
      kind: {
        kind: "cover",
        entityId: "cover.undo_curtain",
        subtype: "curtain",
        positionPercent: 40,
        positionWritable: true,
        motion: "stopped",
        faultText: null,
        openDescription: "Open",
        closeDescription: "Close",
        pauseDescription: "Pause",
        batteryPercent: null,
      },
    };
    const ac: SmartDevice = {
      id: "undo_ac",
      name: "卧室空调",
      roomId: "study",
      roomName: "书房",
      model: "xiaomi.ac.v1",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "climate.undo_ac",
        isOn: true,
        hvacMode: "cool",
        availableModes: ["off", "cool"],
        targetTemperature: 25,
        currentTemperature: 26,
        minTemp: 16,
        maxTemp: 30,
        step: 1,
        fanMode: null,
        availableFanModes: [],
        swingMode: "off",
        availableSwingModes: ["off", "vertical", "both"],
      },
    };

    const { serviceCalls } = await mountWithHADevices([plug, curtain, ac], { climatePanel: false });

    // 1. Plug child-lock: enable -> Undo -> UI reverts to unlocked and next click sends turn_on.
    await click('[data-expand-device="undo_plug"]');
    await click('[data-pluglock="undo_plug"]');
    assert.equal(element('[data-pluglock="undo_plug"]').getAttribute("aria-pressed"), "true");
    assert.match(element('[data-pluglock="undo_plug"]').textContent ?? "", /按键锁：开/);

    await click("#btn-undo");
    assert.equal(element('[data-pluglock="undo_plug"]').getAttribute("aria-pressed"), "false");
    assert.match(element('[data-pluglock="undo_plug"]').textContent ?? "", /按键锁：关/);
    assert.deepEqual(serviceCalls.at(-1), {
      domain: "switch",
      service: "turn_off",
      entity_id: "switch.undo_plug_lock",
      data: {},
    });

    await click('[data-pluglock="undo_plug"]');
    assert.deepEqual(serviceCalls.at(-1), {
      domain: "switch",
      service: "turn_on",
      entity_id: "switch.undo_plug_lock",
      data: {},
    });

    // 2. Cover position slider: 40% -> 75% -> Undo -> slider & readout revert to 40%.
    await click('[data-expand-device="undo_curtain"]');
    const coverSlider = element<HTMLInputElement>('[data-coverpos="undo_curtain"]');
    coverSlider.value = "75";
    coverSlider.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(element<HTMLInputElement>('[data-coverpos="undo_curtain"]').value, "75");
    assert.match(element('[data-tile-id="undo_curtain"] .cc-slider-label strong').textContent ?? "", /75%/);

    await click("#btn-undo");
    assert.equal(element<HTMLInputElement>('[data-coverpos="undo_curtain"]').value, "40");
    assert.match(element('[data-tile-id="undo_curtain"] .cc-slider-label strong').textContent ?? "", /40%/);
    assert.deepEqual(serviceCalls.at(-1), {
      domain: "cover",
      service: "set_cover_position",
      entity_id: "cover.undo_curtain",
      data: { position: 40 },
    });

    // 3. Climate swingMode: "off" -> "both" -> Undo -> active pill reverts to "off".
    await click('[data-expand-device="undo_ac"]');
    await click('[data-acswing="undo_ac:both"]');
    assert.equal(element('[data-acswing="undo_ac:both"]').getAttribute("aria-pressed"), "true");

    await click("#btn-undo");
    assert.equal(element('[data-acswing="undo_ac:off"]').getAttribute("aria-pressed"), "true");
    assert.equal(element('[data-acswing="undo_ac:both"]').getAttribute("aria-pressed"), "false");
    assert.deepEqual(serviceCalls.at(-1), {
      domain: "climate",
      service: "set_swing_mode",
      entity_id: "climate.undo_ac",
      data: { swing_mode: "off" },
    });
  });

  it("preserves prior lastUndoAction when a feed action fails and omits empty mode pills on swing-only climate strips", async () => {
    const swingOnlyAc: SmartDevice = {
      id: "swing_only_ac",
      name: "新风摆风器",
      roomId: "living",
      roomName: "客厅",
      model: "xiaomi.ac.swing",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "miot:swing_only_ac:2:1",
        isOn: true,
        hvacMode: "off",
        availableModes: ["off"],
        targetTemperature: 24,
        currentTemperature: 25,
        minTemp: 16,
        maxTemp: 30,
        step: 1,
        fanMode: null,
        availableFanModes: [],
        powerWritable: false,
        temperatureWritable: false,
        swingMode: "off",
        availableSwingModes: ["off", "vertical"],
      },
    };
    const feeder: SmartDevice = {
      id: "feeder_fail",
      name: "喂食器",
      roomId: "living",
      roomName: "客厅",
      model: "mmgg.feeder.petfeeder",
      isOnline: true,
      kind: {
        kind: "generic",
        deviceType: "pet-feeder",
        typeTitle: "喂食器",
        isOn: false,
        powerControl: null,
        readouts: [],
        alerts: [],
        symbolName: null,
        isReadOnly: false,
      },
    };

    const { app } = await mountWithHADevices([swingOnlyAc, feeder], { climatePanel: true });
    app.deviceFacets = {
      feeder_fail: [
        makeFacet({
          id: "2.a1",
          kind: "button",
          serviceName: "pet-feeder",
          name: "pet-food-out",
          title: "出粮",
          isWritable: true,
          writesByDefault: false,
          isConfirmedWrite: true,
          isHighValue: true,
          arguments: [{ propertyId: 1, name: "feeding-measure", format: "uint8", range: { min: 1, max: 5, step: 1 } }],
          portionArgumentIndex: 0,
          target: { kind: "action", entityId: "miot-action:feeder_fail:2:1" },
        }),
      ],
    };
    app.render();
    await setImmediate();

    await click('[data-expand-device="swing_only_ac"]');
    assertMissing(document.querySelector('[data-tile-id="swing_only_ac"] .cc-segmented-pills.is-even'));
    assert.ok(document.querySelector('[data-acswing="swing_only_ac:vertical"]'));

    const existingUndo = {
      summary: "已打开台灯",
      steps: [{ deviceId: "other_lamp", commands: [{ kind: "setLightPower" as const, entityId: "light.other", isOn: false }] }],
      expiresAtMs: Date.now() + 60_000,
    };
    app.lastUndoAction = existingUndo;
    app.applyCommand = async () => {
      app.replyBanner = { text: "网络超时", source: "控制失败", isError: true };
      app.render();
      return false;
    };

    await click('[data-expand-device="feeder_fail"]');
    await click('[data-more-settings-toggle="feeder_fail"]');
    await click('[data-facet-action="feeder_fail|2.a1"]');
    await click('[data-facet-action="feeder_fail|2.a1"]');

    assert.equal(app.lastUndoAction, existingUndo, "failed feed action must not wipe previous undo action");
  });
});
