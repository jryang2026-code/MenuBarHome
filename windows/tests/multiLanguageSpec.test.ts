import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import { currentLanguage, setLanguage, type AppLanguage } from "../src/core/i18n.js";
import { MiotSpecResolver, parseMiotDeviceSpec, type MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import type { HttpTransport } from "../src/core/miCloud/session.js";
import { applyMultiLanguage, parseMultiLanguageDocument, valueListKey } from "../src/core/miCloud/specLocalization.js";
import { applySpecPatches, type SpecPatchesDocument } from "../src/core/miCloud/specPatches.js";

const REPO_ROOT = path.resolve(import.meta.dirname, "..", "..");

interface Golden {
  urn: string;
  model: string;
  spec: unknown;
  multiLanguage: unknown;
  expected: Record<AppLanguage, Record<string, string>>;
  patches: SpecPatchesDocument;
  patchedLabel: string;
}

function loadGolden(): Golden {
  const file = path.join(REPO_ROOT, "Tests", "Fixtures", "miot_multi_language_golden.json");
  return JSON.parse(fs.readFileSync(file, "utf8")) as Golden;
}

function labels(spec: MiotDeviceSpec): Record<string, string> {
  const out: Record<string, string> = {};
  for (const service of spec.services) {
    if (service.description !== undefined) out[`service:${String(service.iid).padStart(3, "0")}`] = service.description;
    for (const property of service.properties) {
      const base = `service:${String(service.iid).padStart(3, "0")}:property:${String(property.iid).padStart(3, "0")}`;
      if (property.description !== undefined) out[base] = property.description;
      property.valueList?.forEach((item, index) => {
        out[valueListKey(service.iid, property.iid, index)] = item.description;
      });
    }
  }
  return out;
}

function device(golden: Golden) {
  return { did: "ac1", name: "AC", model: golden.model, isOnline: true, specType: golden.urn };
}

describe("MIoT official multiLanguage labels and cache", () => {
  it("applies the shared golden fixture for zh-Hans, zh-Hant and en; patches still win", () => {
    const golden = loadGolden();
    const spec = parseMiotDeviceSpec(golden.spec);
    const doc = parseMultiLanguageDocument(golden.multiLanguage);
    assert.ok(spec);
    assert.ok(doc);

    const saved = currentLanguage();
    try {
      for (const lang of ["zh-Hans", "zh-Hant", "en"] as const) {
        setLanguage(lang);
        const localized = applyMultiLanguage(spec, doc, currentLanguage());
        assert.deepEqual(labels(localized), golden.expected[lang]);
        const patched = applySpecPatches(localized, golden.model, golden.patches);
        assert.equal(labels(patched)["service:002:property:001"], golden.patchedLabel);
      }
    } finally {
      setLanguage(saved);
    }
    assert.equal(spec.services[0]?.description, "Device Information");
  });

  it("fetches translations alongside the spec, caches them, and never blocks on translation failure", async () => {
    const golden = loadGolden();
    const specBody = JSON.stringify(golden.spec);
    const languageBody = JSON.stringify(golden.multiLanguage);
    const seen: string[] = [];
    const transport: HttpTransport = async (req) => {
      seen.push(req.url);
      if (req.url.includes("/instance?type=")) {
        return { status: 200, headers: {}, body: specBody };
      }
      if (req.url.includes("/instance/v2/multiLanguage?urn=")) {
        return { status: 200, headers: {}, body: languageBody };
      }
      return { status: 404, headers: {}, body: "" };
    };

    const resolver = new MiotSpecResolver(transport);
    const saved = currentLanguage();
    try {
      setLanguage("zh-Hant");
      await resolver.resolve(device(golden));
      await resolver.waitForMultiLanguageRefresh(golden.urn);
      const resolved = await resolver.resolve(device(golden));
      assert.deepEqual(labels(resolved), golden.expected["zh-Hant"]);
      assert.ok(seen.some((url) => url.includes("/instance/v2/multiLanguage?urn=")));
      const before = seen.length;
      await resolver.resolve(device(golden));
      assert.equal(seen.length, before);
    } finally {
      setLanguage(saved);
    }

    const failing = new MiotSpecResolver(async (req) => {
      if (req.url.includes("/instance?type=")) {
        return { status: 200, headers: {}, body: specBody };
      }
      if (req.url.includes("/instance/v2/multiLanguage?urn=")) {
        return { status: 503, headers: {}, body: "unavailable" };
      }
      return { status: 404, headers: {}, body: "" };
    });
    const raw = await failing.resolve(device(golden));
    assert.equal(raw.type, golden.urn);
    assert.deepEqual(labels(raw), labels(parseMiotDeviceSpec(golden.spec)!));
  });

  it("keeps cached translated labels when the network goes offline", async () => {
    const golden = loadGolden();
    let online = true;
    const transport: HttpTransport = async (req) => {
      if (!online) throw new Error("offline");
      if (req.url.includes("/instance?type=")) {
        return { status: 200, headers: {}, body: JSON.stringify(golden.spec) };
      }
      if (req.url.includes("/instance/v2/multiLanguage?urn=")) {
        return { status: 200, headers: {}, body: JSON.stringify(golden.multiLanguage) };
      }
      return { status: 404, headers: {}, body: "" };
    };
    const resolver = new MiotSpecResolver(transport);
    const saved = currentLanguage();
    try {
      setLanguage("zh-Hans");
      await resolver.resolve(device(golden));
      await resolver.waitForMultiLanguageRefresh(golden.urn);
      const first = await resolver.resolve(device(golden));
      online = false;
      const stale = await resolver.resolve(device(golden));
      assert.deepEqual(labels(stale), labels(first));
      assert.deepEqual(labels(stale), golden.expected["zh-Hans"]);
    } finally {
      setLanguage(saved);
    }
  });
});
