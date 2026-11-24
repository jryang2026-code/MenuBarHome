import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { answerStateQuery, parseStateQuery } from "../src/core/assistant/stateQuery.js";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { applyTemperatureUnit } from "../src/core/temperature.js";

/** Assistant state-query replies must speak the °C/°F preference, not always °C (#428). */

const envSensor: SmartDevice = {
  id: "dev_env",
  name: "客厅温度计",
  roomId: "living",
  roomName: "客厅",
  model: "miaomiaoce.sensor_ht.t1",
  isOnline: true,
  kind: { kind: "sensor", temperature: 27.5, humidity: 52, battery: 80 },
};

const livingAC: SmartDevice = {
  id: "dev_living_ac",
  name: "客厅空调",
  roomId: "living",
  roomName: "客厅",
  model: "xiaomi.aircondition.mc5",
  isOnline: true,
  kind: {
    kind: "climate",
    entityId: "climate.dev_living_ac",
    isOn: true,
    hvacMode: "cool",
    availableModes: ["off", "cool", "heat", "dry", "fan_only"],
    targetTemperature: 26,
    currentTemperature: 27.5,
    minTemp: 16,
    maxTemp: 31,
    step: 0.5,
    fanMode: "auto",
    availableFanModes: ["low", "medium", "high", "auto"],
  },
};

const devices: readonly SmartDevice[] = [envSensor, livingAC];

describe("assistant temperature replies follow the °C/°F display preference (#428)", () => {
  it("answers the room temperature in the display unit, one decimal like the panel", () => {
    setLanguage("zh-Hans");
    applyTemperatureUnit("en-US", "celsius");
    const celsius = answerStateQuery(parseStateQuery("客厅温度计温度是多少")!, devices);
    assert.equal(celsius?.reply, "客厅温度计：27.5°C");

    applyTemperatureUnit("en-US", "fahrenheit");
    const fahrenheit = answerStateQuery(parseStateQuery("客厅温度计温度是多少")!, devices);
    assert.equal(fahrenheit?.reply, "客厅温度计：81.5°F");

    // An integer reading keeps the panel's temperature-only one-decimal shape in both units.
    const whole: SmartDevice = {
      ...envSensor,
      kind: { kind: "sensor", temperature: 26, humidity: null, battery: null },
    };
    applyTemperatureUnit("en-US", "celsius");
    assert.equal(answerStateQuery(parseStateQuery("客厅温度计温度是多少")!, [whole])?.reply, "客厅温度计：26.0°C");
    applyTemperatureUnit("en-US", "fahrenheit");
    assert.equal(answerStateQuery(parseStateQuery("客厅温度计温度是多少")!, [whole])?.reply, "客厅温度计：78.8°F");
    applyTemperatureUnit("zh-Hans-CN", "celsius");
  });

  it("answers the AC setpoint in the display unit with the panel's digits", () => {
    setLanguage("zh-Hans");
    applyTemperatureUnit("en-US", "celsius");
    const celsius = answerStateQuery(parseStateQuery("客厅空调设置了几度")!, devices);
    assert.equal(celsius?.reply, "客厅空调：设定 26°C");

    applyTemperatureUnit("en-US", "fahrenheit");
    const fahrenheit = answerStateQuery(parseStateQuery("客厅空调设置了几度")!, devices);
    assert.equal(fahrenheit?.reply, "客厅空调：设定 79°F");
    applyTemperatureUnit("zh-Hans-CN", "celsius");
  });
});
