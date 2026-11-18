import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { partitionTestFileArgs } from "../scripts/test-file.mjs";

const scriptPath = fileURLToPath(new URL("../scripts/test-file.mjs", import.meta.url));

// Unit coverage for the argument partitioning. The real "--test-name-pattern
// only runs matching tests" subprocess check lives in
// scripts/test_harness_tools.sh instead of here: this suite runs inside a
// `node --test` process, and a nested inner runner inherits
// NODE_TEST_CONTEXT=child-v8, switches to event serialization, and neither
// prints reporter output nor propagates test failures through its exit code.
describe("partitionTestFileArgs", () => {
  it("regroups runner flags written after the test file", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "tests/ui.test.ts",
      "--test-name-pattern",
      "stops a Xiaomi cloud live view",
    ]);
    assert.deepEqual(runnerArgs, ["--test-name-pattern", "stops a Xiaomi cloud live view"]);
    assert.deepEqual(testFiles, ["tests/ui.test.ts"]);
  });

  it("keeps runner flags written before the test file working", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "--test-name-pattern=foo",
      "--test-only",
      "tests/ui.test.ts",
      "tests/core.test.ts",
    ]);
    assert.deepEqual(runnerArgs, ["--test-name-pattern=foo", "--test-only"]);
    assert.deepEqual(testFiles, ["tests/ui.test.ts", "tests/core.test.ts"]);
  });

  it("does not let boolean flags swallow the next file path", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "--test-only",
      "tests/ui.test.ts",
    ]);
    assert.deepEqual(runnerArgs, ["--test-only"]);
    assert.deepEqual(testFiles, ["tests/ui.test.ts"]);
  });

  it("consumes a value for value-taking --experimental-test flags", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "--experimental-test-isolation",
      "none",
      "tests/core.test.ts",
    ]);
    assert.deepEqual(runnerArgs, ["--experimental-test-isolation", "none"]);
    assert.deepEqual(testFiles, ["tests/core.test.ts"]);
  });

  it("reports no files when only options are given", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs(["--test-name-pattern", "foo"]);
    assert.deepEqual(runnerArgs, ["--test-name-pattern", "foo"]);
    assert.deepEqual(testFiles, []);
  });
});

describe("test-file.mjs usage validation", () => {
  const runScript = (args: string[]) =>
    // The no-file paths exit before any runner subprocess is spawned, so no
    // nested test runner is involved here.
    spawnSync(process.execPath, [scriptPath, ...args], { encoding: "utf-8" });

  it("prints usage and exits 2 when no test file is given", () => {
    const missing = runScript([]);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr ?? "", /usage: npm run test:file --/);

    const optionsOnly = runScript(["--test-name-pattern", "foo"]);
    assert.equal(optionsOnly.status, 2);
    assert.match(optionsOnly.stderr ?? "", /usage: npm run test:file --/);
  });
});
