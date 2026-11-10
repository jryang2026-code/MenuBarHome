import "./dom.js";
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { cloudFixture, cloudFixtureHookIndex } from "./cloudFixture.js";

describe("cloud fixture hooks", () => {
  it("returns each indexed hook and no other function", () => {
    const cloud = cloudFixture([]);
    const functions = Object.entries(cloud)
      .filter((entry): entry is [string, (...args: never[]) => unknown] => typeof entry[1] === "function")
      .map(([name]) => name)
      .sort();
    assert.deepEqual(functions, Object.keys(cloudFixtureHookIndex).sort());
  });
});
