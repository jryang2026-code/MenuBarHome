import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ManualControlPolicy, ModelActionPolicy } from "../src/core/assistant/actionPolicy.js";
import { deviceCategory } from "../src/core/assistant/deviceCategory.js";
import { IntentValidator } from "../src/core/assistant/intent.js";
import {
  DEVICE_PROFILES,
  MANUAL_CONTROL_FALLBACK_RULES,
  type ManualControlRules,
} from "../src/core/miCloud/facets.js";
import type { FacetControl, SmartDevice } from "../src/core/models.js";

/**
 * The Windows 更多设置 confirmation table, one row per macOS branch:
 * `MijiaCore.ManualControlPolicy.facetRequiresConfirmation` (`Sources/MijiaCore/ManualControlPolicy.swift`)
 * is the reference. Rows that Swift tests already pin name that test.
 */
function device(kind: SmartDevice["kind"], overrides: Partial<SmartDevice> = {}): SmartDevice {
  return {
    id: `did_${kind.kind}`,
    name: kind.kind,
    roomId: "room",
    roomName: "Room",
    model: `vendor.${kind.kind}.v1`,
    isOnline: true,
    kind,
    ...overrides,
  };
}

function generic(deviceType: string, overrides: Partial<SmartDevice> = {}): SmartDevice {
  return device(
    {
      kind: "generic",
      deviceType,
      typeTitle: deviceType,
      isOn: false,
      powerControl: null,
      isReadOnly: false,
      readouts: [],
      symbolName: null,
    },
    { id: `did_${deviceType}`, name: deviceType, model: `generic.${deviceType}`, ...overrides },
  );
}

/** A climate card; `deviceCategory` decides heater by model and the four macOS name hints. */
function climateDevice(name: string, model: string): SmartDevice {
  return device(
    {
      kind: "climate",
      entityId: "miot:climate:2",
      isOn: false,
      hvacMode: "off",
      availableModes: ["off", "heat"],
      targetTemperature: 22,
      currentTemperature: 20,
      minTemp: 16,
      maxTemp: 30,
      step: 1,
      fanMode: null,
      availableFanModes: [],
    },
    { id: `did_${model}`, name, model },
  );
}

/** `deviceCategory` calls this a heater: a climate card whose model names a heater. */
function heater(): SmartDevice {
  return climateDevice("电暖器", "dmaker.heater.v1");
}

/** An appliance card; `heats` drives both the water-heater branch and the power hazard table. */
function applianceDevice(name: string, model: string, heats: boolean): SmartDevice {
  return device(
    {
      kind: "appliance",
      entityId: "miot:water_heater:2",
      isOn: true,
      powerPresent: true,
      powerWritable: true,
      currentMode: "heat",
      availableModes: ["off", "heat"],
      modeWritable: true,
      targetTemperature: 45,
      currentTemperature: 44,
      minTemp: 30,
      maxTemp: 75,
      step: 1,
      temperatureWritable: true,
      statusText: null,
      faultText: null,
      remainingMinutes: null,
      startAction: null,
      pauseAction: null,
      stopAction: null,
      powerEntityId: "miot:water_heater:2",
      modeEntityId: "miot:water_heater:3",
      temperatureEntityId: "miot:water_heater:4",
      light: null,
      fanLevel: null,
      currentHumidity: null,
      symbolName: null,
      roomReading: false,
      heats,
    },
    { id: `did_${model}`, name, model },
  );
}

/** An appliance card that heats water, so `spec.heats` drives the water-heater branch. */
function waterHeater(): SmartDevice {
  return applianceDevice("热水器", "xiaomi.waterheater.v1", true);
}

function plug(): SmartDevice {
  return device(
    {
      kind: "plug",
      switchEntityId: "miot:plug:2",
      isOn: false,
      powerWatts: null,
      childLockEntityId: null,
      isChildLocked: false,
    },
    { id: "did_plug", name: "插座", model: "chuangmi.plug.v3" },
  );
}

function curtain(): SmartDevice {
  return device(
    {
      kind: "cover",
      entityId: "miot:curtain:2",
      subtype: "curtain",
      positionPercent: 50,
      positionWritable: true,
      openDescription: null,
      closeDescription: null,
      pauseDescription: null,
      batteryPercent: null,
      faultText: null,
      motion: "stopped",
    },
    { id: "did_curtain", name: "窗帘", model: "lumi.curtain.v1" },
  );
}

function facet(overrides: Partial<FacetControl> = {}): FacetControl {
  return {
    id: "2.2",
    kind: "toggle",
    name: "speed",
    title: null,
    serviceName: "vendor-service",
    unit: null,
    scale: null,
    value: 1,
    options: [],
    range: null,
    isWritable: true,
    writesByDefault: false,
    isHighValue: false,
    target: { kind: "property", entityId: "miot:vendor:2", piid: 2 },
    ...overrides,
  };
}

const offHeatOptions = [
  { value: 0, label: "Off" },
  { value: 1, label: "Heat" },
];

interface Row {
  readonly name: string;
  readonly control: FacetControl;
  readonly value: unknown;
  readonly device: SmartDevice;
  readonly expected: boolean;
  readonly source: string;
}

const rows: readonly Row[] = [
  {
    name: "a button always asks, whitelisted or not",
    control: facet({ kind: "button", writesByDefault: true, target: { kind: "action", entityId: "miot:vendor:a2" } }),
    value: undefined,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift L132: `if facet.kind == .button { return true }`",
  },
  {
    name: "an action target always asks even behind a toggle row",
    control: facet({ kind: "toggle", writesByDefault: true, target: { kind: "action", entityId: "miot:vendor:a2" } }),
    value: true,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift L134: `facet.target?.isAction == true`",
  },
  {
    name: "a cover mode write asks even when the facet is whitelisted",
    control: facet({
      kind: "select",
      name: "mode",
      serviceName: "curtain",
      options: offHeatOptions,
      writesByDefault: true,
      value: 0,
    }),
    value: 1,
    device: curtain(),
    expected: true,
    source: "ManualControlPolicy.swift L139-140: `isMode` on a cover or cover service",
  },
  {
    name: "a strictly high-risk device type asks even with a whitelisted facet",
    control: facet({ name: "on", writesByDefault: true, value: false }),
    value: true,
    device: generic("lock"),
    expected: true,
    source: "ManualControlPolicy.swift `strictlyHighRisk`: `lock` matches the device type",
  },
  {
    name: "a strictly high-risk service asks even for the off direction",
    control: facet({ name: "on", serviceName: "lock", writesByDefault: true, value: true }),
    value: false,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift `strictlyHighRisk`: off still asks (#6 review)",
  },
  {
    name: "an indicator token stays direct",
    control: facet({ name: "indicator", serviceName: "indicator-light", writesByDefault: true, value: false }),
    value: true,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift `lowRiskTokens` / `lowRiskServices`",
  },
  {
    name: "a child-lock token stays direct",
    control: facet({ name: "child-lock", writesByDefault: true, value: false }),
    value: true,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift `lowRiskHA`: `name.contains(\"child-lock\")`",
  },
  {
    name: "a night light stays direct",
    control: facet({ name: "night-light", writesByDefault: true, value: false }),
    value: true,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift `lowRiskHA`: `name.contains(\"night-light\")`",
  },
  {
    name: "a buzzer service stays direct",
    control: facet({ name: "volume", serviceName: "buzzer", writesByDefault: true, value: 1 }),
    value: 2,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift `lowRiskServices`",
  },
  {
    name: "an HA switch turned on follows the heater power table and asks",
    control: facet({ name: "bath-heater-ptc", serviceName: "switch", value: false }),
    value: true,
    device: heater(),
    expected: true,
    source: "ManualControlPolicy.swift L167: `service == \"switch\"` → `.power(isOn)`",
  },
  {
    name: "an HA switch reports its direction as 0/1 strings too",
    control: facet({ name: "bath-heater-ptc", serviceName: "switch", value: "0" }),
    value: "1",
    device: heater(),
    expected: true,
    source: "ManualControlPolicy.swift L167 switch branch reads the 0/1 form as a boolean",
  },
  {
    name: "an HA switch turned off on a heater stays direct",
    control: facet({ name: "bath-heater-ptc", serviceName: "switch", value: true }),
    value: false,
    device: heater(),
    expected: false,
    source: "ManualControlPolicy.swift L167: the same power table keeps off direct",
  },
  {
    name: "any heater target temperature asks, hotter or cooler",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "heater", value: 22 }),
    value: 28,
    device: heater(),
    expected: true,
    source: "ManualControlPolicy.swift L176-180: heater category falls through to `return true`",
  },
  {
    name: "turning a heater off stays direct",
    control: facet({ name: "on", serviceName: "heater", value: true }),
    value: false,
    device: heater(),
    expected: false,
    source: "ManualControlPolicy.swift L177: `if isPower, let isOn = value?.miotBool { return isOn }`",
  },
  {
    name: "a heater mode set to Off stays direct",
    control: facet({ kind: "select", name: "mode", serviceName: "heater", options: offHeatOptions, value: 1 }),
    value: 0,
    device: heater(),
    expected: false,
    source: "ManualControlPolicy.swift L178: `selectedMode` off is direct",
  },
  {
    name: "a heater mode set to Heat asks",
    control: facet({ kind: "select", name: "mode", serviceName: "heater", options: offHeatOptions, value: 0 }),
    value: 1,
    device: heater(),
    expected: true,
    source: "ManualControlPolicy.swift L178",
  },
  {
    name: "a heating service switched on asks",
    control: facet({ name: "on", serviceName: "heater", value: false }),
    value: true,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift L183-185: `heatingService { return isOn }`",
  },
  {
    name: "a heating service switched off stays direct",
    control: facet({ name: "on", serviceName: "heater", value: true }),
    value: false,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift L183-185",
  },
  {
    name: "a water heater target above the current reading asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: 45 }),
    value: 60,
    device: waterHeater(),
    expected: true,
    source: "ManualControlPolicy.swift L196-198: `requested > current`",
  },
  {
    name: "a water heater target below the current reading stays direct",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: 45 }),
    value: 40,
    device: waterHeater(),
    expected: false,
    source: "ManualControlPolicy.swift L196-198",
  },
  {
    name: "a water heater target with no reading asks on a heating service",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: null }),
    value: 50,
    device: waterHeater(),
    expected: true,
    source: "ManualControlPolicy.swift L199: `if heatingService { return true }`",
  },
  {
    name: "a generic facet outside the whitelist asks",
    control: facet({ name: "speed", value: 1 }),
    value: 2,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift L208-210: generic devices outside the whitelist",
  },
  {
    name: "a whitelisted write on a generic device stays direct",
    control: facet({ name: "speed", writesByDefault: true, value: 1 }),
    value: 2,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift L208-210",
  },
  {
    name: "a generic mode set to Off stays direct",
    control: facet({ kind: "select", name: "mode", options: offHeatOptions, value: 1 }),
    value: 0,
    device: generic("vendor-box"),
    expected: false,
    source: "ManualControlPolicy.swift L213-215: an off mode is not a hazard",
  },
  {
    name: "a generic mode set to Heat asks",
    control: facet({ kind: "select", name: "mode", options: offHeatOptions, value: 0 }),
    value: 1,
    device: generic("vendor-box"),
    expected: true,
    source: "ManualControlPolicy.swift L213-215",
  },
  {
    name: "a padded reading never parses, so a water heater target still asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: " 99 " }),
    value: 60,
    device: waterHeater(),
    expected: true,
    source: "Swift `Double(\" 99 \")` is nil, so the branch falls through to `heatingService → true`",
  },
  {
    name: "an empty reading never parses",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "" }),
    value: 60,
    device: waterHeater(),
    expected: true,
    source: "Swift `Double(\"\")` is nil",
  },
  {
    name: "a binary literal is not a Swift number",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "0b101010" }),
    value: 40,
    device: waterHeater(),
    expected: true,
    source: "Swift `Double(\"0b101010\")` is nil while `Number` reads 42, so 40 stays direct only in the loose parser",
  },
  {
    name: "an exponent is a number on both sides",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "1e3" }),
    value: 60,
    device: waterHeater(),
    expected: false,
    source: "Swift `Double(\"1e3\")` is 1000, so 60 is cooler and stays direct",
  },
  {
    name: "a hex reading stays unknown and asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "0x10" }),
    value: 40,
    device: waterHeater(),
    expected: true,
    source: "Hex floats are deliberately unparsed here, unlike Swift, so the unknown reading asks",
  },
  {
    name: "a hex float that overflows in the parser stays unknown and asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "0x0p1024" }),
    value: 40,
    device: waterHeater(),
    expected: true,
    source: "0 * Infinity used to be NaN, which compared as not-hotter and skipped the confirmation",
  },
  {
    name: "an infinite reading stays unknown and asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "inf" }),
    value: 40,
    device: waterHeater(),
    expected: true,
    source: "inf is not a plain decimal, so the reading is unknown and the heating branch asks",
  },
  {
    name: "a nan reading stays unknown and asks",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "water-heater", value: "nan" }),
    value: 40,
    device: waterHeater(),
    expected: true,
    source: "nan compared as not-hotter and skipped the confirmation; now it is unknown and asks",
  },
  {
    name: "a padded 0/1 switch value never parses, so a plug write stays direct",
    control: facet({ name: "bath-heater-ptc", serviceName: "switch", value: " 1 " }),
    value: " 1 ",
    device: plug(),
    expected: false,
    source: "Swift reads a padded 0/1 as nil, so the switch branch never reaches the power table",
  },
  {
    name: "a padded mode value does not select the Off option",
    control: facet({ kind: "select", name: "mode", options: [{ value: 1, label: "Off" }], value: 0 }),
    value: " 1 ",
    device: generic("vendor-box"),
    expected: true,
    source: "Swift `intValue` on \" 1 \" is nil, so the raw string is not the Off label",
  },
  {
    name: "a 冷暖 air conditioner lowering its temperature stays direct",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "air-conditioner", value: 26 }),
    value: 22,
    device: climateDevice("冷暖空调", "xiaomi.aircondition.v1"),
    expected: false,
    source: "Swift `IntentDeviceCategory.heaterNameHints` is 电暖/暖气/取暖/暖风, so 冷暖 is a plain climate card",
  },
  {
    name: "a 电暖器 is a heater by name even when its model says nothing",
    control: facet({ kind: "slider", name: "target-temperature", serviceName: "air-conditioner", value: 26 }),
    value: 18,
    device: climateDevice("电暖器", "xiaomi.aircondition.v1"),
    expected: true,
    source: "Swift `heaterNameHints.contains(where: device.name.contains)`",
  },
  {
    name: "an appliance named with 暖 only is never re-categorised by name",
    control: facet({ name: "on", serviceName: "vendor-service", value: false }),
    value: true,
    device: applianceDevice("浴室暖风", "viomi.bath.v1", false),
    expected: false,
    source: "Swift `IntentDeviceCategory` reads the kind first; `.appliance` is not `.climate`",
  },
];

describe("更多设置 confirmation rule (#5, #6)", () => {
  for (const row of rows) {
    it(row.name, () => {
      assert.equal(
        ManualControlPolicy.facetRequiresConfirmation(row.control, row.value, row.device),
        row.expected,
        row.source,
      );
    });
  }

  it("custom rules de-escalate a service the default table asks about (Tests/MijiaCoreTests/ManualControlPolicyTests.swift rulesDriveFacetConfirmation)", () => {
    const dev = generic("vendor-box");
    const control = facet();
    assert.equal(ManualControlPolicy.facetRequiresConfirmation(control, 2, dev), true);

    const custom: ManualControlRules = {
      strictlyHighRisk: [],
      heatingService: [],
      lowRiskServices: ["vendor-service"],
      lowRiskTokens: [],
    };
    assert.equal(ManualControlPolicy.facetRequiresConfirmation(control, 2, dev, custom), false);
  });

  it("custom strictly-high-risk entries keep an off direction behind a confirmation (ManualControlPolicyTests rulesDriveStrictRisk)", () => {
    const dev = generic("vendor-box");
    const control = facet({ name: "on", value: true });
    assert.equal(ManualControlPolicy.facetRequiresConfirmation(control, false, dev), false);

    const custom: ManualControlRules = {
      strictlyHighRisk: ["vendor-service"],
      heatingService: [],
      lowRiskServices: [],
      lowRiskTokens: [],
    };
    assert.equal(ManualControlPolicy.facetRequiresConfirmation(control, false, dev, custom), true);
  });

  it("the bundled document carries the manual-control table macOS reads (ManualControlPolicyTests bundledRulesMatchDocument)", () => {
    assert.deepEqual(DEVICE_PROFILES.manualControlPolicy, MANUAL_CONTROL_FALLBACK_RULES);
  });
});

describe("assistant device category heater rule (#143)", () => {
  it("uses the four macOS heater name hints and the same model checks", () => {
    assert.equal(deviceCategory(climateDevice("冷暖空调", "xiaomi.aircondition.v1")), "climate");
    assert.equal(deviceCategory(climateDevice("电暖器", "xiaomi.aircondition.v1")), "heater");
    assert.equal(deviceCategory(climateDevice("暖气", "xiaomi.aircondition.v1")), "heater");
    assert.equal(deviceCategory(climateDevice("取暖器", "xiaomi.aircondition.v1")), "heater");
    assert.equal(deviceCategory(climateDevice("暖风机", "xiaomi.aircondition.v1")), "heater");
    assert.equal(deviceCategory(climateDevice("客厅空调", "zhimi.heater.za2")), "heater", "the model still decides");
    assert.equal(deviceCategory(climateDevice("客厅空调", "xiaomi.blanket.v1")), "heater", "a blanket model heats");
    assert.equal(
      deviceCategory(applianceDevice("浴室暖风", "viomi.bath.v1", false)),
      "other",
      "an appliance is never re-categorised by its name",
    );
  });

  it("keeps heater-named 热水器 on the stricter heater rule while plain 热水器 stays hotter-only", () => {
    const heaterNamed = climateDevice("取暖热水器", "viomi.wh.e1");
    const plainWaterHeater = climateDevice("厨房热水器", "viomi.wh.e1");
    assert.equal(
      ModelActionPolicy.needsConfirmation(
        { targetId: heaterNamed.id, operation: { kind: "targetTemperature", celsius: 20 } },
        [heaterNamed],
      ),
      true,
    );
    assert.equal(
      ModelActionPolicy.needsConfirmation(
        { targetId: plainWaterHeater.id, operation: { kind: "targetTemperature", celsius: 20 } },
        [plainWaterHeater],
      ),
      false,
    );
  });

  it("preserves appliance power intents during IntentValidator.normalize when writable", () => {
    const wh = waterHeater();
    assert.deepEqual(IntentValidator.normalize({ kind: "power", isOn: false }, wh), {
      kind: "power",
      isOn: false,
    });
    const readOnlyWh: SmartDevice = {
      ...wh,
      kind: wh.kind.kind === "appliance" ? { ...wh.kind, powerWritable: false } : wh.kind,
    };
    assert.equal(IntentValidator.normalize({ kind: "power", isOn: true }, readOnlyWh), null);
  });
});
