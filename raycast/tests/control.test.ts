import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizePowerAction, powerCommand } from "../src/control.ts";
import type { RaycastDevice } from "../src/snapshot.ts";

const device = {
  id: "dev_study_lamp",
  name: "书房台灯",
  isActiveOn: true,
} as RaycastDevice;

test("explicit on and off are absolute power links", () => {
  assert.deepEqual(powerCommand(device, "on"), {
    route: "power",
    params: [
      ["device", "dev_study_lamp"],
      ["on", "true"],
    ],
  });
  assert.deepEqual(powerCommand(device, "off"), {
    route: "power",
    params: [
      ["device", "dev_study_lamp"],
      ["on", "false"],
    ],
  });
});

test("toggle uses the app's toggle route instead of inverting a cached state", () => {
  assert.deepEqual(powerCommand(device, "toggle"), {
    route: "toggle",
    params: [["device", "dev_study_lamp"]],
  });
  // 快照里是开着，但 toggle 链接不带任何目标状态：由应用在执行时自己解析。
  assert.equal(powerCommand(device, "toggle").params.some(([key]) => key === "on"), false);
});

test("normalizePowerAction accepts only the three documented actions", () => {
  assert.equal(normalizePowerAction("On"), "on");
  assert.equal(normalizePowerAction(" off "), "off");
  assert.equal(normalizePowerAction("TOGGLE"), "toggle");
  assert.equal(normalizePowerAction("turn_on"), undefined);
  assert.equal(normalizePowerAction(undefined), undefined);
  assert.equal(normalizePowerAction(42), undefined);
});
