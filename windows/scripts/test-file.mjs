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
// regroups argv so every --test* flag lands after --test and before the files.
const RUNNER_BOOLEAN_FLAGS = new Set(["--test", "--test-only", "--test-force-exit"]);

function isRunnerOption(token) {
  return token.startsWith("-");
}

function takesValue(token) {
  if (token.includes("=")) return false;
  if (token.startsWith("--test") || token.startsWith("--experimental-test")) {
    return !RUNNER_BOOLEAN_FLAGS.has(token);
  }
  // Unknown options pass through as single tokens; value-taking unknown
  // options should use the --opt=val form so the value is never mistaken for
  // a test file.
  return false;
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
