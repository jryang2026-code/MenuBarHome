import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptPath = fileURLToPath(import.meta.url);
const windowsRoot = path.resolve(path.dirname(scriptPath), "..");
const usageText = "usage: npm run test:file -- <test-file>";

function printUsage() {
  console.error(usageText);
}

const args = process.argv.slice(2);
if (args.length === 0 || args.every((arg) => arg.startsWith("-"))) {
  printUsage();
  process.exit(2);
}

const child = spawnSync(
  process.execPath,
  ["--import", "./tests/tsLoader.mjs", "--test", ...args],
  { cwd: windowsRoot, stdio: "inherit" },
);
process.exit(child.status === null ? 1 : child.status);
