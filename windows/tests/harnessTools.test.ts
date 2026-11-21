import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { partitionTestFileArgs } from "../scripts/test-file.mjs";

const scriptPath = fileURLToPath(new URL("../scripts/test-file.mjs", import.meta.url));

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

  // Boolean --test* / --experimental-test* switches. Every one of these must
  // stay a single token, no matter where it sits relative to <test-file>.
  const BOOLEAN_FLAGS = [
    "--experimental-test-coverage",
    "--experimental-test-module-mocks",
    "--experimental-test-snapshots",
    "--test-only",
    "--test-force-exit",
    "--test-update-snapshots",
    "--test-randomize",
  ];

  it("never lets a single boolean flag swallow the test file", () => {
    for (const flag of BOOLEAN_FLAGS) {
      const { runnerArgs, testFiles } = partitionTestFileArgs([flag, "tests/harnessTools.test.ts"]);
      assert.deepEqual(runnerArgs, [flag], `${flag} must stay a single token`);
      assert.deepEqual(testFiles, ["tests/harnessTools.test.ts"], `${flag} must not consume the file`);
    }
  });

  it("keeps boolean flags written before the test file as single tokens", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      ...BOOLEAN_FLAGS,
      "tests/harnessTools.test.ts",
    ]);
    assert.deepEqual(runnerArgs, BOOLEAN_FLAGS);
    assert.deepEqual(testFiles, ["tests/harnessTools.test.ts"]);
  });

  it("keeps boolean flags written after the test file as single tokens", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "tests/harnessTools.test.ts",
      ...BOOLEAN_FLAGS,
    ]);
    assert.deepEqual(runnerArgs, BOOLEAN_FLAGS);
    assert.deepEqual(testFiles, ["tests/harnessTools.test.ts"]);
  });

  it("mixes value-taking and boolean flags without losing the file", () => {
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "--test-name-pattern",
      "stops a Xiaomi cloud live view",
      "--experimental-test-coverage",
      "tests/ui.test.ts",
      "--test-force-exit",
      "--test-concurrency",
      "2",
    ]);
    assert.deepEqual(runnerArgs, [
      "--test-name-pattern",
      "stops a Xiaomi cloud live view",
      "--experimental-test-coverage",
      "--test-force-exit",
      "--test-concurrency",
      "2",
    ]);
    assert.deepEqual(testFiles, ["tests/ui.test.ts"]);
  });

  it("treats an unrecognized runner flag as a single token", () => {
    // Safe default for flags a future Node adds: without a value classification
    // the following test file must never be swallowed.
    const { runnerArgs, testFiles } = partitionTestFileArgs([
      "--test-some-future-switch",
      "tests/ui.test.ts",
    ]);
    assert.deepEqual(runnerArgs, ["--test-some-future-switch"]);
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
