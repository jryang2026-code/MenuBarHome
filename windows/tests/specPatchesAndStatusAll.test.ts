import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import {
  MiotSpecResolver,
  parseMiotDeviceSpec,
  parseMiotInstanceIndex,
} from "../src/core/miCloud/spec.js";
import {
  applySpecPatches,
  SPEC_PATCHES,
  type SpecPatchesDocument,
} from "../src/core/miCloud/specPatches.js";

const REPO_ROOT = path.resolve(import.meta.dirname, "..", "..");

describe("MIoT status=all and Shared/specPatches.json contract", () => {
  it("parseMiotInstanceIndex prefers released > omitted > preview > debug and highest version within status", () => {
    const index = parseMiotInstanceIndex({
      instances: [
        { model: "acme.ac.v1", version: 3, status: "debug", type: "urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:3" },
        { model: "acme.ac.v1", version: 1, status: "released", type: "urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:1" },
        { model: "acme.ac.v1", version: 2, status: "released", type: "urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:2" },
        { model: "acme.kettle.dbg", version: 1, status: "debug", type: "urn:miot-spec-v2:device:kettle:0000A009:acme-dbg:1" },
        { model: "acme.fresh.mix", version: 4, status: "debug", type: "urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:4" },
        { model: "acme.fresh.mix", version: 1, status: "preview", type: "urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:1" },
      ],
    });

    assert.equal(index["acme.ac.v1"], "urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:2");
    assert.equal(index["acme.kettle.dbg"], "urn:miot-spec-v2:device:kettle:0000A009:acme-dbg:1");
    assert.equal(index["acme.fresh.mix"], "urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:1");
  });

  it("MiotSpecResolver fetches status=all first and falls back to status=released when all is unavailable", async () => {
    const debugUrn = "urn:miot-spec-v2:device:kettle:0000A009:yunmi-v1:1";
    const specPayload = JSON.stringify({
      type: debugUrn,
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:kettle:00007813:yunmi-v1:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:yunmi-v1:1", format: "float", access: ["read"] },
          ],
          actions: [],
        },
      ],
    });

    const seenAll: string[] = [];
    const resolverAll = new MiotSpecResolver(async (req) => {
      seenAll.push(req.url);
      if (req.url.includes("/instances?status=all")) {
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            instances: [{ model: "yunmi.kettle.v1", version: 1, status: "debug", type: debugUrn }],
          }),
        };
      }
      if (req.url.includes("/instance?type=")) {
        return { status: 200, headers: {}, body: specPayload };
      }
      return { status: 404, headers: {}, body: "" };
    });

    const resolvedAll = await resolverAll.resolve({
      did: "k1",
      name: "Kettle",
      model: "yunmi.kettle.v1",
      isOnline: true,
      specType: null,
    });
    assert.equal(resolvedAll.type, debugUrn);
    assert.ok(seenAll.some((u) => u.includes("/instances?status=all")));
    assert.equal(seenAll.some((u) => u.includes("/instances?status=released")), false);

    const seenFallback: string[] = [];
    const resolverFallback = new MiotSpecResolver(async (req) => {
      seenFallback.push(req.url);
      if (req.url.includes("/instances?status=all")) {
        return { status: 503, headers: {}, body: "unavailable" };
      }
      if (req.url.includes("/instances?status=released")) {
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            instances: [{ model: "yunmi.kettle.v1", version: 1, status: "released", type: debugUrn }],
          }),
        };
      }
      if (req.url.includes("/instance?type=")) {
        return { status: 200, headers: {}, body: specPayload };
      }
      return { status: 404, headers: {}, body: "" };
    });

    const resolvedFallback = await resolverFallback.resolve({
      did: "k1",
      name: "Kettle",
      model: "yunmi.kettle.v1",
      isOnline: true,
      specType: null,
    });
    assert.equal(resolvedFallback.type, debugUrn);
    assert.ok(seenFallback.some((u) => u.includes("/instances?status=all")));
    assert.ok(seenFallback.some((u) => u.includes("/instances?status=released")));
  });

  it("applies Shared/specPatches.json golden fixture identically to macOS and is idempotent", async () => {
    assert.equal(SPEC_PATCHES.schemaVersion, 1);

    const fixturePath = path.join(REPO_ROOT, "Tests", "Fixtures", "spec_patches_golden.json");
    const golden = JSON.parse(fs.readFileSync(fixturePath, "utf8")) as {
      model: string;
      patches: SpecPatchesDocument;
      input: unknown;
      expected: unknown;
    };

    const inputSpec = parseMiotDeviceSpec(golden.input);
    const expectedSpec = parseMiotDeviceSpec(golden.expected);
    assert.ok(inputSpec);
    assert.ok(expectedSpec);

    const patched = applySpecPatches(inputSpec, golden.model, golden.patches);
    assert.deepEqual(patched, expectedSpec);
    assert.deepEqual(applySpecPatches(patched, golden.model, golden.patches), expectedSpec);

    const resolver = new MiotSpecResolver(
      async () => ({ status: 200, headers: {}, body: JSON.stringify(golden.input) }),
      undefined,
      undefined,
      golden.patches,
    );
    const viaResolver = await resolver.resolve({
      did: "ac1",
      name: "AC",
      model: golden.model,
      isOnline: true,
      specType: inputSpec.type,
    });
    assert.deepEqual(viaResolver, expectedSpec);
  });
});
