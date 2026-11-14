import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { inferFallbackSpec, miotShortName } from "../src/core/miCloudClient.js";

const cases: ReadonlyArray<readonly [string, string, string, string]> = [
  ["model", "vendor.sensor_ht.1", "温湿度", "temperature-humidity-sensor"],
  ["name", "vendor.unknown.1", "空调", "air-conditioner"],
  ["suffix", "vendor.thing.fan", "未知", "fan"],
  ["default", "vendor.unknown.1", "未知", "outlet"],
];

describe("fallback spec table (#185)", () => {
  for (const [kind, model, name, expected] of cases) {
    it(`${kind} match for ${expected}`, () => {
      assert.equal(miotShortName(inferFallbackSpec({ model, name }).type), expected);
    });
  }

  it("keeps every guessed property read-only", () => {
    for (const [, model, name] of cases) {
      for (const service of inferFallbackSpec({ model, name }).services) {
        for (const property of service.properties) {
          assert.deepEqual(property.access, ["read"]);
        }
      }
    }
  });
});
