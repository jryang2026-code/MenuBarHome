import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  checkForUpdate,
  isEligibleForRollout,
  loadOrCreateUpdateInstallId,
  parseRolloutPercentage,
  updateRolloutBucket,
} from "../src/core/updateChecker.js";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const GOLDEN_PATH = path.join(REPO_ROOT, "Tests", "Fixtures", "update_rollout_golden.json");

interface GoldenCorpus {
  bucketCases: Array<{ installId: string; version: string; expectedBucket: number }>;
  eligibilityCases: Array<{
    installId: string;
    version: string;
    rolloutPercentage: number | null;
    manual: boolean;
    expectedEligible: boolean;
  }>;
  metadataCases: Array<{
    label: string;
    json: Record<string, unknown>;
    expectedRolloutPercentage: number | null;
  }>;
}

describe("update staged rollout parity", () => {
  it("matches the cross-platform golden corpus for bucketing, eligibility, and metadata parsing", () => {
    const golden = JSON.parse(fs.readFileSync(GOLDEN_PATH, "utf8")) as GoldenCorpus;

    for (const item of golden.bucketCases) {
      assert.equal(updateRolloutBucket(item.installId, item.version), item.expectedBucket);
    }

    for (const item of golden.eligibilityCases) {
      assert.equal(
        isEligibleForRollout(item.installId, item.version, item.rolloutPercentage, item.manual),
        item.expectedEligible,
      );
    }

    for (const item of golden.metadataCases) {
      const actual = parseRolloutPercentage(item.json) ?? null;
      assert.equal(actual, item.expectedRolloutPercentage, `Mismatch for case: ${item.label}`);
    }
  });

  it("persists a locally generated install ID and reuses it across calls", () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => {
        store.set(key, value);
      },
    };
    let generated = 0;
    const first = loadOrCreateUpdateInstallId(storage, () => {
      generated += 1;
      return "550e8400-e29b-41d4-a716-446655440000";
    });
    const second = loadOrCreateUpdateInstallId(storage, () => {
      generated += 1;
      return "ffffffff-ffff-4fff-bfff-ffffffffffff";
    });
    assert.equal(first, "550e8400-e29b-41d4-a716-446655440000");
    assert.equal(second, first);
    assert.equal(generated, 1);
  });

  it("gates automatic checks by rollout percentage while manual checks always see the release", async () => {
    const installId = "550e8400-e29b-41d4-a716-446655440000"; // bucket 18 for 1.5.0
    const body = (pct: number) =>
      JSON.stringify({
        tag_name: "v1.5.0",
        html_url: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.5.0",
        body: `Release notes\n<!-- rollout_percentage: ${pct} -->`,
      });

    const gated = await checkForUpdate({
      currentVersion: "1.4.0",
      enabled: true,
      lastCheckedAtMs: null,
      nowMs: 1_750_000_000_000,
      installId,
      requestLatest: async () => ({ status: 200, body: body(10) }),
    });
    assert.equal(gated.requested, true);
    assert.equal(gated.updateAvailable, false);
    assert.equal(gated.release, null);

    const manual = await checkForUpdate({
      currentVersion: "1.4.0",
      enabled: true,
      lastCheckedAtMs: 1_750_000_000_000,
      nowMs: 1_750_000_000_000,
      force: true,
      installId,
      requestLatest: async () => ({ status: 200, body: body(0) }),
    });
    assert.equal(manual.requested, true);
    assert.equal(manual.updateAvailable, true);
    assert.equal(manual.release?.version, "1.5.0");

    const ramped = await checkForUpdate({
      currentVersion: "1.4.0",
      enabled: true,
      lastCheckedAtMs: null,
      nowMs: 1_750_000_000_000,
      installId,
      requestLatest: async () => ({ status: 200, body: body(25) }),
    });
    assert.equal(ramped.updateAvailable, true);
    assert.equal(ramped.release?.version, "1.5.0");
  });
});
