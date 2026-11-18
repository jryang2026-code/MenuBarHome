import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const scriptPath = fileURLToPath(import.meta.url);
const windowsRoot = path.resolve(path.dirname(scriptPath), "..");
const usageText =
  "usage: npm run test:file -- [--test-name-pattern <pattern>] <test-file> [...]";

// Node stops parsing its own CLI options at the first positional argument (the
// test file), so runner flags must come before the files when we spawn it.
// Callers, however, pass them in any order -- `test-file.mjs a.test.ts
// --test-name-pattern foo` is the natural thing to type. partitionTestFileArgs
// regroups argv so every runner flag lands after --test and before the files.

// The only options that eat the next argv token are those that take a value
// in the space-separated form. The list is taken from `node --help` (options
// documented as `--opt=...`) rather than inferred from the flag name: plenty
// of `--test*` / `--experimental-test*` flags are pure switches, and treating
// those as value-taking would swallow a following <test-file>.
//
// Anything missing here -- including booleans like --test-only,
// --test-force-exit, --test-update-snapshots, --experimental-test-coverage,
// --experimental-test-module-mocks, --experimental-test-snapshots, and every
// flag a future Node adds -- stays a single token, which is the safe default.
// Value-taking options that are not listed must be written as --opt=value.
const RUNNER_VALUE_OPTIONS = new Set([
  // Test runner.
  "--test-name-pattern",
  "--test-skip-pattern",
  "--test-reporter",
  "--test-reporter-destination",
  "--test-concurrency",
  "--test-timeout",
  "--test-global-setup",
  "--test-isolation",
  "--experimental-test-isolation",
  "--test-rerun-failures",
  "--test-shard",
  "--test-random-seed",
  "--test-coverage-branches",
  "--test-coverage-functions",
  "--test-coverage-lines",
  "--test-coverage-include",
  "--test-coverage-exclude",
  "--experimental-test-tag-filter",
  // Module loading and process startup.
  "--import",
  "--require",
  "-r",
  "--loader",
  "--experimental-loader",
  "--conditions",
  "-C",
  "--env-file",
  "--env-file-if-exists",
  "--input-type",
  // Watch mode and runtime limits, which callers put in front of the files.
  "--watch-path",
  "--watch-kill-signal",
  "--max-old-space-size",
  "--max-semi-space-size",
  "--stack-size",
  "--title",
  "--unhandled-rejections",
]);

function isRunnerOption(token) {
  return token.startsWith("-");
}

function takesValue(token) {
  // --opt=value carries its own value, so it never consumes the next token.
  if (token.includes("=")) return false;
  return RUNNER_VALUE_OPTIONS.has(token);
}

export function partitionTestFileArgs(argv) {
  const runnerArgs = [];
  const testFiles = [];
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (isRunnerOption(token)) {
      if (takesValue(token) && i + 1 < argv.length) {
        runnerArgs.push(token, argv[i + 1]);
        i += 1;
      } else {
        runnerArgs.push(token);
      }
    } else {
      testFiles.push(token);
    }
  }
  return { runnerArgs, testFiles };
}

function printUsage() {
  console.error(usageText);
}

function run(argv) {
  const { runnerArgs, testFiles } = partitionTestFileArgs(argv);
  if (testFiles.length === 0) {
    printUsage();
    process.exit(2);
  }
  const child = spawnSync(
    process.execPath,
    ["--import", "./tests/tsLoader.mjs", "--test", ...runnerArgs, ...testFiles],
    { cwd: windowsRoot, stdio: "inherit" },
  );
  process.exit(child.status === null ? 1 : child.status);
}

const isEntry = import.meta.url === pathToFileURL(process.argv[1] || "").href;
if (isEntry) {
  run(process.argv.slice(2));
}
