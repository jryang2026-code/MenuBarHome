import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import * as nodeModule from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isMainThread } from "node:worker_threads";

const loaderDir = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(loaderDir, "..");

function sha256File(filePath) {
  try {
    return createHash("sha256").update(readFileSync(filePath)).digest("hex");
  } catch {
    return null;
  }
}

function discoverSharedNodeModules() {
  if (process.env.MMB_DISABLE_SHARED_NODE_MODULES === "1") return null;
  const localTs = path.join(windowsRoot, "node_modules", "typescript");
  if (existsSync(localTs)) return null;
  const expectedLockHash = sha256File(path.join(windowsRoot, "package-lock.json"));
  if (!expectedLockHash) return null;
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
      const candidateModules = path.join(candidateWindows, "node_modules");
      if (!existsSync(path.join(candidateModules, "typescript"))) continue;
      if (sha256File(path.join(candidateWindows, "package-lock.json")) === expectedLockHash) {
        return candidateModules;
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

let ts = null;
try {
  const mod = await import("typescript");
  ts = mod.default ?? mod;
} catch {
  if (sharedRequire) {
    try {
      const tsEntry = sharedRequire.resolve("typescript");
      const mod = await import(pathToFileURL(tsEntry).href);
      ts = mod.default ?? mod;
    } catch {
      ts = null;
    }
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
  compiler = ts,
  stripTypes = nodeModule.stripTypeScriptTypes,
) {
  if (compiler) {
    return compiler.transpileModule(source, {
      fileName,
      compilerOptions: {
        target: compiler.ScriptTarget.ES2022,
        module: compiler.ModuleKind.ESNext,
        jsx: fileName.endsWith(".tsx") ? compiler.JsxEmit.ReactJSX : undefined,
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
      const outputText = transpileTypeScript(source, fileName);
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
