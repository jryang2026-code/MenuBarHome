import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  CLAIM_LADDER,
  DEVICE_CLAIMS,
  claimAllows,
  claimFallbackTokens,
  preferredClaimServices,
} from "../src/core/miCloud/deviceClaims.js";
import type { MiotDeviceSpec, MiotService } from "../src/core/miCloud/spec.js";
import { APPLIANCE_SERVICE_NAMES, preferredMiotServices, primaryMiotService } from "../src/core/miCloud/synthesis.js";

// #26: the MIoT claim ladder, its device-type aliases and its two claim conditions live in
// `Shared/deviceClaims.json`. macOS decodes the same document in `DeviceClaims.swift`, and
// `scripts/check_device_rules.py` keeps both ends' code tables aligned with it.

const urn = (kind: "device" | "service" | "property", name: string): string =>
  `urn:miot-spec-v2:${kind}:${name}:00000000:test:1`;

const service = (name: string, properties: readonly { name: string; format: string }[] = []): MiotService => ({
  iid: 2,
  type: urn("service", name),
  properties: properties.map((property, index) => ({
    iid: index + 1,
    type: urn("property", property.name),
    format: property.format,
    access: ["read", "write"],
  })),
  actions: [],
});

const spec = (deviceType: string, services: readonly MiotService[]): MiotDeviceSpec => ({
  type: urn("device", deviceType),
  services,
});

describe("shared MIoT claim rules (Shared/deviceClaims.json)", () => {
  it("reads the ladder, aliases and appliance list from the shared document", () => {
    assert.equal(DEVICE_CLAIMS.schemaVersion, 1);
    assert.equal(CLAIM_LADDER.length, 45);
    assert.equal(CLAIM_LADDER[0], "air-conditioner");
    assert.equal(CLAIM_LADDER.at(-1), "temperature-humidity-sensor");
    // Windows renders the two rungs macOS has no builder for; the document says so explicitly.
    const tv = DEVICE_CLAIMS.ladder.find((entry) => entry.service === "television");
    const stb = DEVICE_CLAIMS.ladder.find((entry) => entry.service === "stb");
    assert.deepEqual(tv?.renderers, ["windows"]);
    assert.deepEqual(stb?.renderers, ["windows"]);
    assert.deepEqual([...APPLIANCE_SERVICE_NAMES], [...DEVICE_CLAIMS.applianceServices]);
    assert.ok(APPLIANCE_SERVICE_NAMES.includes("cleanfly-dryer"));
  });

  it("keeps the device-type aliases the Windows table used to spell out", () => {
    assert.deepEqual(preferredClaimServices("outlet"), ["outlet", "switch"]);
    assert.deepEqual(preferredClaimServices("camera"), ["camera-control", "video-doorbell"]);
    assert.deepEqual(preferredClaimServices("kettle"), ["kettle", "ble-kettle", "water-dispenser"]);
    assert.deepEqual(preferredClaimServices("stb"), ["stb", "television"]);
    assert.deepEqual(preferredClaimServices("fish-tank"), ["fish-tank"]);
    assert.deepEqual(preferredMiotServices("stb"), ["stb", "television"]);
    assert.deepEqual(preferredMiotServices("bath-heater"), ["ptc-bath-heater", "bath-heater"]);
  });

  it("keeps the MIoT television card the shared ladder renders on this platform", () => {
    const television = spec("television", [service("television", [{ name: "on", format: "bool" }])]);
    assert.equal(primaryMiotService(television)?.type, urn("service", "television"));
    const setTopBox = spec("stb", [service("stb", [{ name: "on", format: "bool" }])]);
    assert.equal(primaryMiotService(setTopBox)?.type, urn("service", "stb"));
  });

  it("claims an electronic-valve only when it meters electric power (#265)", () => {
    const shutOffValve = spec("electronic-valve", [service("electronic-valve", [{ name: "on", format: "bool" }])]);
    assert.equal(claimAllows("electronic-valve", shutOffValve), false);
    assert.equal(primaryMiotService(shutOffValve), undefined);

    const breaker = spec("electronic-valve", [
      service("electronic-valve", [{ name: "on", format: "bool" }]),
      service("power-consumption", [{ name: "electric-power", format: "float" }]),
    ]);
    assert.equal(claimAllows("electronic-valve", breaker), true);
    assert.equal(primaryMiotService(breaker)?.type, urn("service", "electronic-valve"));
  });

  it("claims a water-heater service only for a water heater (#300)", () => {
    const waterHeater = spec("water-heater", [service("water-heater", [{ name: "on", format: "bool" }])]);
    assert.equal(claimAllows("water-heater", waterHeater), true);

    const kettle = spec("kettle", [service("water-heater", [{ name: "on", format: "bool" }])]);
    assert.equal(claimAllows("water-heater", kettle), false);
    assert.equal(primaryMiotService(kettle), undefined);
  });

  it("lets a light service claim light-like types on the last fallback rung (#296)", () => {
    assert.deepEqual([...claimFallbackTokens("light")], ["light", "lamp"]);
    assert.deepEqual([...claimFallbackTokens("switch")], []);
  });
});
