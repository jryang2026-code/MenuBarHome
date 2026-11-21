import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import * as nodeModule from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isMainThread, threadId } from "node:worker_threads";

const loaderDir = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(loaderDir, "..");
const repoRoot = path.resolve(windowsRoot, "..");
const cacheDir = path.join(os.tmpdir(), "mmb-tsloader-v2");
const memoryTranspileCache = new Map();

function sha256File(filePath) {
  try {
    return createHash("sha256").update(readFileSync(filePath)).digest("hex");
  } catch {
    return null;
  }
}

function candidateHasMatchingModules(candidateWindows, expectedLockHash) {
  const candidateModules = path.join(candidateWindows, "node_modules");
  if (!existsSync(path.join(candidateModules, "typescript"))) return null;
  if (sha256File(path.join(candidateWindows, "package-lock.json")) !== expectedLockHash) return null;
  return candidateModules;
}

function discoverFromGitCommonDir(expectedLockHash) {
  try {
    const dotGitPath = path.join(repoRoot, ".git");
    if (!existsSync(dotGitPath) || !statSync(dotGitPath).isFile()) return null;
    const raw = readFileSync(dotGitPath, "utf8").trim();
    if (!raw.startsWith("gitdir:")) return null;
    const gitDir = path.resolve(repoRoot, raw.slice("gitdir:".length).trim());
    const commonGitDir = path.resolve(gitDir, "..", "..");
    const mainRepoRoot = path.dirname(commonGitDir);
    const matched = candidateHasMatchingModules(path.join(mainRepoRoot, "windows"), expectedLockHash);
    if (matched) return matched;
  } catch {
    return null;
  }
  return null;
}

function discoverSharedNodeModules() {
  if (process.env.MMB_DISABLE_SHARED_NODE_MODULES === "1") return null;
  const localTs = path.join(windowsRoot, "node_modules", "typescript");
  if (existsSync(localTs)) return null;
  const cachedEnv = process.env.MMB_SHARED_WINDOWS_NODE_MODULES;
  if (cachedEnv && existsSync(path.join(cachedEnv, "typescript"))) {
    return cachedEnv;
  }
  const expectedLockHash = sha256File(path.join(windowsRoot, "package-lock.json"));
  if (!expectedLockHash) return null;
  const commonMatch = discoverFromGitCommonDir(expectedLockHash);
  if (commonMatch) {
    process.env.MMB_SHARED_WINDOWS_NODE_MODULES = commonMatch;
    return commonMatch;
  }
  try {
    const raw = execFileSync("git", ["worktree", "list", "--porcelain"], {
      cwd: windowsRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    for (const line of raw.split(/\r?\n/)) {
      if (!line.startsWith("worktree ")) continue;
      const wtPath = line.slice("worktree ".length).trim();
      const candidateWindows = path.join(wtPath, "windows");
      if (path.resolve(candidateWindows) === windowsRoot) continue;
      const matched = candidateHasMatchingModules(candidateWindows, expectedLockHash);
      if (matched) {
        process.env.MMB_SHARED_WINDOWS_NODE_MODULES = matched;
        return matched;
      }
    }
  } catch {
    return null;
  }
  return null;
}

const sharedNodeModules = discoverSharedNodeModules();
const sharedAnchorURL = sharedNodeModules
  ? pathToFileURL(path.join(path.dirname(sharedNodeModules), "_mmb_shared_.mjs")).href
  : null;
const sharedRequire = sharedNodeModules
  ? nodeModule.createRequire(sharedAnchorURL)
  : null;
const localRequire = nodeModule.createRequire(import.meta.url);

let tsCompiler = undefined;
function getTypeScriptCompiler() {
  if (tsCompiler !== undefined) return tsCompiler;
  try {
    const mod = localRequire("typescript");
    tsCompiler = mod.default ?? mod;
    return tsCompiler;
  } catch {
    if (sharedRequire) {
      try {
        const mod = sharedRequire("typescript");
        tsCompiler = mod.default ?? mod;
        return tsCompiler;
      } catch {
        tsCompiler = null;
        return null;
      }
    }
    tsCompiler = null;
    return null;
  }
}

const EXT_REWRITES = [
  [".js", [".ts", ".tsx"]],
  [".jsx", [".tsx"]],
  [".mjs", [".mts"]],
  [".cjs", [".cts"]],
];

export function transpileTypeScript(
  source,
  fileName,
  compiler = undefined,
  stripTypes = nodeModule.stripTypeScriptTypes,
) {
  const effectiveCompiler = compiler === undefined ? getTypeScriptCompiler() : compiler;
  if (effectiveCompiler) {
    return effectiveCompiler.transpileModule(source, {
      fileName,
      compilerOptions: {
        target: effectiveCompiler.ScriptTarget.ES2022,
        module: effectiveCompiler.ModuleKind.ESNext,
        jsx: fileName.endsWith(".tsx") ? effectiveCompiler.JsxEmit.ReactJSX : undefined,
        isolatedModules: true,
        inlineSourceMap: true,
      },
    }).outputText;
  }
  try {
    return stripTypes(source, {
      mode: "transform",
      sourceUrl: fileName,
    });
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ERR_INVALID_ARG_VALUE") {
      try {
        return stripTypes(source, {
          mode: "strip",
          sourceUrl: fileName,
        });
      } catch (stripError) {
        if (stripError && typeof stripError === "object" && stripError.code === "ERR_INVALID_TYPESCRIPT_SYNTAX") {
          throw new Error(
            `${stripError.message} (install TypeScript via 'cd windows && npm ci' to transpile runtime TypeScript syntax)`,
            { cause: stripError },
          );
        }
        throw stripError;
      }
    }
    throw error;
  }
}

function loadCachedTypeScript(source, fileName) {
  const compiler = getTypeScriptCompiler();
  const compilerMode = compiler ? `tsc:${compiler.version ?? "1"}` : "strip";
  const key = createHash("sha1")
    .update(compilerMode)
    .update("\0")
    .update(fileName)
    .update("\0")
    .update(source)
    .digest("hex");
  const mem = memoryTranspileCache.get(key);
  if (mem !== undefined) return mem;
  const diskPath = path.join(cacheDir, `${key}.js`);
  try {
    if (existsSync(diskPath)) {
      const cached = readFileSync(diskPath, "utf8");
      memoryTranspileCache.set(key, cached);
      return cached;
    }
  } catch {
  }
  const outputText = transpileTypeScript(source, fileName, compiler);
  memoryTranspileCache.set(key, outputText);
  try {
    mkdirSync(cacheDir, { recursive: true });
    const tmpPath = `${diskPath}.${process.pid}.${threadId}.tmp`;
    writeFileSync(tmpPath, outputText, "utf8");
    renameSync(tmpPath, diskPath);
  } catch {
  }
  return outputText;
}

export function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith(".") && context.parentURL) {
    for (const [ext, candidates] of EXT_REWRITES) {
      if (specifier.endsWith(ext)) {
        const stem = specifier.slice(0, -ext.length);
        for (const tsExt of candidates) {
          const tsUrl = new URL(stem + tsExt, context.parentURL);
          if (tsUrl.protocol === "file:" && existsSync(fileURLToPath(tsUrl))) {
            return { url: tsUrl.href, shortCircuit: true };
          }
        }
        break;
      }
    }
  }
  const canFallback =
    sharedAnchorURL &&
    !specifier.startsWith(".") &&
    !specifier.startsWith("/") &&
    !specifier.startsWith("node:") &&
    !specifier.startsWith("file:");
  const tryShared = (error) => {
    if (canFallback && error && typeof error === "object" && error.code === "ERR_MODULE_NOT_FOUND") {
      try {
        return nextResolve(specifier, { ...context, parentURL: sharedAnchorURL });
      } catch {
        throw error;
      }
    }
    throw error;
  };
  try {
    const result = nextResolve(specifier, context);
    if (result && typeof result.then === "function") {
      return result.catch(tryShared);
    }
    return result;
  } catch (error) {
    return tryShared(error);
  }
}

export function load(url, context, nextLoad) {
  if (url.startsWith("file:")) {
    const parsedUrl = new URL(url);
    const pathname = parsedUrl.pathname;
    if (pathname.endsWith(".json")) {
      const raw = readFileSync(fileURLToPath(parsedUrl), "utf8").replace(/^\uFEFF/, "");
      const parsed = JSON.parse(raw);
      return { format: "module", shortCircuit: true, source: `export default ${JSON.stringify(parsed)};` };
    }
    if (/\.(?:[cm]?ts|tsx)$/.test(pathname)) {
      const fileName = fileURLToPath(parsedUrl);
      const source = readFileSync(fileName, "utf8");
      const outputText = loadCachedTypeScript(source, fileName);
      return { format: "module", shortCircuit: true, source: outputText };
    }
  }
  return nextLoad(url, context);
}

if (typeof nodeModule.registerHooks === "function") {
  nodeModule.registerHooks({ resolve, load });
} else if (isMainThread) {
  nodeModule.register("./tsLoader.mjs", import.meta.url);
}
