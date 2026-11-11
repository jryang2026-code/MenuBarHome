#!/usr/bin/env node
// Context & lint hook for Antigravity (.agents/hooks.json) and Claude Code (.claude/settings.json).
// Injects path-scoped .claude/rules/*.md once per conversation when matching files are read/edited,
// and runs actionlint automatically when .github/workflows/*.yml is modified.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const RULES_DIR = path.join(REPO_ROOT, ".claude", "rules");

function globToRegExp(glob) {
  const norm = glob.replace(/\\/g, "/").replace(/^\.\//, "");
  let rx = "^";
  let i = 0;
  while (i < norm.length) {
    if (norm.startsWith("/**/", i)) {
      rx += "(?:/.+/|/)";
      i += 4;
    } else if (i === 0 && norm.startsWith("**/", i)) {
      rx += "(?:.+/)?";
      i += 3;
    } else if (i + 3 === norm.length && norm.startsWith("/**", i)) {
      rx += "(?:/.*)?";
      i += 3;
    } else if (norm.startsWith("**", i)) {
      rx += ".*";
      i += 2;
    } else if (norm[i] === "*") {
      rx += "[^/]*";
      i += 1;
    } else if (norm[i] === "?") {
      rx += "[^/]";
      i += 1;
    } else if (norm[i] === "{") {
      const close = norm.indexOf("}", i);
      if (close !== -1) {
        const alts = norm
          .slice(i + 1, close)
          .split(",")
          .map((s) => s.replace(/[.+^${}()|[\]\\]/g, "\\$&"));
        rx += `(?:${alts.join("|")})`;
        i = close + 1;
      } else {
        rx += "\\{";
        i += 1;
      }
    } else {
      rx += norm[i].replace(/[.+^${}()|[\]\\]/g, "\\$&");
      i += 1;
    }
  }
  rx += "$";
  return new RegExp(rx);
}

function loadScopedRules() {
  if (!fs.existsSync(RULES_DIR)) return [];
  const entries = fs.readdirSync(RULES_DIR).filter((f) => f.endsWith(".md")).sort();
  const rules = [];
  for (const file of entries) {
    const fullPath = path.join(RULES_DIR, file);
    const raw = fs.readFileSync(fullPath, "utf8").replace(/\r\n/g, "\n");
    if (!raw.startsWith("---\n")) continue;
    const endIdx = raw.indexOf("\n---", 4);
    if (endIdx === -1) continue;
    const fm = raw.slice(4, endIdx);
    const body = raw.slice(endIdx + 4).trim();
    const globs = [];
    let inPaths = false;
    for (const line of fm.split("\n")) {
      const topMatch = line.match(/^paths:\s*(.*)$/);
      if (topMatch) {
        inPaths = true;
        const inline = topMatch[1].trim();
        if (inline.startsWith("[") && inline.endsWith("]")) {
          for (const part of inline.slice(1, -1).split(",")) {
            const clean = part.trim().replace(/^["']|["']$/g, "");
            if (clean) globs.push(clean);
          }
          inPaths = false;
        } else if (inline && !inline.startsWith("#")) {
          globs.push(inline.replace(/^["']|["']$/g, ""));
          inPaths = false;
        }
        continue;
      }
      if (inPaths) {
        const item = line.match(/^\s*-\s*(.+)$/);
        if (item) {
          const clean = item[1].trim().replace(/^["']|["']$/g, "");
          if (clean) globs.push(clean);
        } else if (line.trim() && !line.startsWith(" ") && !line.startsWith("\t")) {
          inPaths = false;
        }
      }
    }
    if (globs.length > 0 && body) {
      rules.push({
        id: `.claude/rules/${file}`,
        globs,
        matchers: globs.map(globToRegExp),
        body,
      });
    }
  }
  return rules;
}

function unwrapString(val) {
  if (typeof val !== "string") return "";
  let s = val.trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    try {
      s = JSON.parse(s);
    } catch {
      s = s.slice(1, -1);
    }
  }
  return typeof s === "string" ? s : "";
}

function toRepoRelative(rawPath, roots) {
  const cleaned = unwrapString(rawPath);
  if (!cleaned) return null;
  for (const root of roots) {
    const abs = path.isAbsolute(cleaned) ? path.resolve(cleaned) : path.resolve(root, cleaned);
    const rel = path.relative(root, abs);
    if (rel && !rel.startsWith("..") && !path.isAbsolute(rel)) {
      return { abs, rel: rel.replace(/\\/g, "/") };
    }
  }
  return null;
}

function extractPathsFromArgs(args) {
  if (!args || typeof args !== "object") return [];
  const candidates = [];
  for (const key of ["Path", "TargetFile", "file_path", "path", "FilePath", "DirectoryPath", "SearchPath"]) {
    if (key in args && args[key]) candidates.push(args[key]);
  }
  if (Array.isArray(args.Paths)) candidates.push(...args.Paths);
  return candidates;
}

function stateFilePath(payload) {
  if (payload.artifactDirectoryPath) {
    return path.join(payload.artifactDirectoryPath, ".context-hook-state.json");
  }
  const cid = (payload.conversationId || payload.session_id || "default").replace(/[^a-zA-Z0-9_-]/g, "_");
  return path.join(os.tmpdir(), "menubarhome-context-hook", `context-hook-${cid}.json`);
}

function readState(stateFile) {
  try {
    if (fs.existsSync(stateFile)) {
      const parsed = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      return {
        injected: Array.isArray(parsed.injected) ? parsed.injected : [],
        pending: Array.isArray(parsed.pending) ? parsed.pending : [],
        actionlintOutput: typeof parsed.actionlintOutput === "string" ? parsed.actionlintOutput : "",
      };
    }
  } catch {}
  return { injected: [], pending: [], actionlintOutput: "" };
}

function writeState(stateFile, state) {
  try {
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n", "utf8");
  } catch {}
}

function maybeRunActionlint(absPath) {
  try {
    const res = spawnSync("actionlint", [absPath], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      timeout: 8000,
    });
    if (res.error) return "";
    if (res.status !== 0) {
      return `actionlint failed on ${path.relative(REPO_ROOT, absPath).replace(/\\/g, "/")}:\n${(res.stdout || "") + (res.stderr || "")}`.trim();
    }
  } catch {}
  return "";
}

function matchRulesForRelPaths(relPaths, rules, alreadySet) {
  const matched = [];
  for (const rule of rules) {
    if (alreadySet.has(rule.id)) continue;
    if (relPaths.some((rel) => rule.matchers.some((rx) => rx.test(rel)))) {
      matched.push(rule.id);
      alreadySet.add(rule.id);
    }
  }
  return matched;
}

function scanRecentTranscriptPaths(transcriptPath, roots) {
  const rels = [];
  try {
    if (!transcriptPath || !fs.existsSync(transcriptPath)) return rels;
    const stat = fs.statSync(transcriptPath);
    const readBytes = Math.min(stat.size, 65536);
    const fd = fs.openSync(transcriptPath, "r");
    const buf = Buffer.alloc(readBytes);
    fs.readSync(fd, buf, 0, readBytes, stat.size - readBytes);
    fs.closeSync(fd);
    const lines = buf.toString("utf8").split("\n").slice(-15);
    for (const line of lines) {
      if (!line.includes("tool_calls")) continue;
      try {
        const obj = JSON.parse(line);
        if (!Array.isArray(obj.tool_calls)) continue;
        for (const tc of obj.tool_calls) {
          for (const raw of extractPathsFromArgs(tc.args)) {
            const info = toRepoRelative(raw, roots);
            if (info) rels.push(info.rel);
          }
        }
      } catch {}
    }
  } catch {}
  return rels;
}

function main() {
  const mode = process.argv[2] || "post-tool";
  let inputText = "";
  try {
    inputText = fs.readFileSync(0, "utf8");
  } catch {}
  let payload = {};
  try {
    payload = inputText ? JSON.parse(inputText) : {};
  } catch {}

  const roots = [REPO_ROOT];
  if (Array.isArray(payload.workspacePaths)) {
    for (const wp of payload.workspacePaths) {
      if (wp && !roots.includes(path.resolve(wp))) roots.push(path.resolve(wp));
    }
  }

  if (mode === "claude-post-edit") {
    const raw = payload?.tool_input?.file_path || payload?.tool_input?.path || "";
    const info = toRepoRelative(raw, roots);
    if (info && /^\.github\/workflows\/[^/]+\.yml$/.test(info.rel)) {
      const lintMsg = maybeRunActionlint(info.abs);
      if (lintMsg) {
        process.stdout.write(
          JSON.stringify({
            hookSpecificOutput: {
              hookEventName: "PostToolUse",
              additionalContext: lintMsg,
            },
          })
        );
        return;
      }
    }
    process.stdout.write("{}");
    return;
  }

  const rules = loadScopedRules();
  const stateFile = stateFilePath(payload);
  const state = readState(stateFile);

  if (mode === "post-tool") {
    const toolName = String(payload?.toolCall?.name || "").toLowerCase();
    const rawCandidates = extractPathsFromArgs(payload?.toolCall?.args);
    const infos = rawCandidates.map((r) => toRepoRelative(r, roots)).filter(Boolean);
    if (infos.length > 0) {
      const known = new Set([...state.injected, ...state.pending]);
      const newlyMatched = matchRulesForRelPaths(
        infos.map((x) => x.rel),
        rules,
        known
      );
      if (newlyMatched.length > 0) {
        state.pending.push(...newlyMatched);
      }
      if (/(edit|write|replace)/.test(toolName)) {
        for (const info of infos) {
          if (/^\.github\/workflows\/[^/]+\.yml$/.test(info.rel)) {
            const lintMsg = maybeRunActionlint(info.abs);
            if (lintMsg) state.actionlintOutput = lintMsg;
          }
        }
      }
      writeState(stateFile, state);
    }
    process.stdout.write("{}");
    return;
  }

  if (mode === "pre-invocation") {
    const recentRels = scanRecentTranscriptPaths(payload.transcriptPath, roots);
    const known = new Set([...state.injected, ...state.pending]);
    if (recentRels.length > 0) {
      const fromTranscript = matchRulesForRelPaths(recentRels, rules, known);
      if (fromTranscript.length > 0) state.pending.push(...fromTranscript);
    }

    const ruleMap = new Map(rules.map((r) => [r.id, r]));
    const toInject = state.pending.filter((id) => !state.injected.includes(id) && ruleMap.has(id));
    const messages = [];

    if (toInject.length > 0) {
      const blocks = toInject.map((id) => `[Path Rule: ${id}]\n${ruleMap.get(id).body}`);
      messages.push(blocks.join("\n\n---\n\n"));
      state.injected.push(...toInject);
    }
    if (state.actionlintOutput) {
      messages.push(state.actionlintOutput);
      state.actionlintOutput = "";
    }
    state.pending = [];
    if (messages.length > 0) {
      writeState(stateFile, state);
      process.stdout.write(
        JSON.stringify({
          injectSteps: [
            {
              systemMessage: {
                systemMessage: messages.join("\n\n"),
              },
            },
          ],
        })
      );
      return;
    }
    process.stdout.write("{}");
    return;
  }

  process.stdout.write("{}");
}

try {
  main();
} catch {
  process.stdout.write("{}");
}
