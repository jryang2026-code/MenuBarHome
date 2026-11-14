#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const windowsRoot = path.resolve(path.dirname(scriptPath), "..");
const repoRoot = path.resolve(windowsRoot, "..");
const usageText = "usage: npm --prefix windows run verify:ui -- [--self-test] [--require-chrome] [--no-build] [--dist <dir>] [--out-dir <dir>] [--chrome <bin>]";

function scenario(id, panelHeight, height, interfaceLanguage, appearance, view) {
  return { id, panelHeight, width: 412, height, interfaceLanguage, appearance, view };
}

export const SCENARIOS = [
  scenario("standard-zh-hans-dark-all", "standard", 680, "zh-Hans", "dark", "all"),
  scenario("standard-zh-hans-light-all", "standard", 680, "zh-Hans", "light", "all"),
  scenario("standard-zh-hant-dark-room", "standard", 680, "zh-Hant", "dark", "room"),
  scenario("standard-en-light-subpage", "standard", 680, "en", "light", "subpage"),
  scenario("compact-zh-hans-dark-subpage", "compact", 580, "zh-Hans", "dark", "subpage"),
  scenario("compact-zh-hant-light-all", "compact", 580, "zh-Hant", "light", "all"),
  scenario("compact-en-dark-all", "compact", 580, "en", "dark", "all"),
  scenario("compact-en-light-room", "compact", 580, "en", "light", "room"),
];

function approxEqual(actual, expected, tolerance = 0.75) {
  return typeof actual === "number" && Math.abs(actual - expected) <= tolerance;
}

export function evaluateSnapshot(snapshot, sc) {
  const failures = [];
  const expectedWidth = sc.width ?? 412, expectedHeight = sc.height, inset = 16;
  const expectedPopoverWidth = expectedWidth - inset * 2, expectedPopoverHeight = expectedHeight - inset * 2;
  if (snapshot.isNativeHost !== true) failures.push(`#app.is-native-host must be true (got ${String(snapshot.isNativeHost)})`);
  if (snapshot.isParked !== false) failures.push(`#app.is-parked must be false (got ${String(snapshot.isParked)})`);
  if (Array.isArray(snapshot.errors) && snapshot.errors.length > 0) failures.push(`console or page errors: ${snapshot.errors.join("; ")}`);
  const app = snapshot.appRect;
  if (!app || !approxEqual(app.width, expectedWidth) || !approxEqual(app.height, expectedHeight)) {
    failures.push(`#app rect must be ${expectedWidth}x${expectedHeight} (got ${app ? `${app.width}x${app.height}` : "null"})`);
  }
  const pop = snapshot.popoverRect;
  if (!pop || !approxEqual(pop.width, expectedPopoverWidth) || !approxEqual(pop.height, expectedPopoverHeight) || !approxEqual(pop.left, inset) || !approxEqual(pop.top, inset) || !approxEqual(pop.right, expectedWidth - inset) || !approxEqual(pop.bottom, expectedHeight - inset)) {
    failures.push(`.cc-popover must be ${expectedPopoverWidth}x${expectedPopoverHeight} at inset ${inset}px (got ${pop ? JSON.stringify(pop) : "null"})`);
  }
  const islands = Array.isArray(snapshot.islands) ? snapshot.islands : [];
  if (islands.length === 0) failures.push("expected at least one visible .win-island");
  for (const island of islands) {
    if (island.left < inset - 0.75 || island.right > expectedWidth - inset + 0.75 || island.top < inset - 0.75 || island.bottom > expectedHeight - inset + 0.75) {
      failures.push(`.win-island (${island.className}) overflows [16, ${expectedWidth - 16}]x[16, ${expectedHeight - 16}]: ${JSON.stringify(island)}`);
    }
  }
  if (typeof snapshot.documentElementScrollWidth !== "number" || snapshot.documentElementScrollWidth > expectedWidth) {
    failures.push(`documentElement.scrollWidth (${String(snapshot.documentElementScrollWidth)}) exceeds ${expectedWidth}`);
  }
  for (const label of Array.isArray(snapshot.chromeLabels) ? snapshot.chromeLabels : []) {
    if (label.scrollWidth > label.clientWidth + 1) failures.push(`chrome label ${label.selector} (${JSON.stringify(label.text)}) truncated: scrollWidth=${label.scrollWidth} > clientWidth=${label.clientWidth}`);
  }
  const minScrollHeight = expectedHeight <= 580 ? 140 : 200;
  if (typeof snapshot.scrollAreaHeight !== "number" || snapshot.scrollAreaHeight < minScrollHeight) {
    failures.push(`.cc-scroll-area height (${String(snapshot.scrollAreaHeight)}px) is below minimum ${minScrollHeight}px for ${expectedHeight}px flyout`);
  }
  if (sc.view === "room" && snapshot.activeRoomId !== "room_living") failures.push(`room view did not activate room_living (activeRoomId=${String(snapshot.activeRoomId)})`);
  if (sc.view === "subpage") {
    const sub = snapshot.subpage;
    if (!sub || sub.mounted !== true) failures.push('.cc-tile.is-subpage[data-tile-id="light.living_ceiling"] did not mount');
    else {
      for (const [name, box] of Object.entries(sub.hiddenControls ?? {})) {
        if (!box || box.width !== 0 || box.height !== 0 || box.display !== "none") failures.push(`subpage background control ${name} must be display:none and 0x0 (got ${JSON.stringify(box)})`);
      }
      if ((sub.visibleSiblingTileCount ?? 0) !== 0) failures.push(`subpage must hide all non-subpage .cc-tile nodes (visibleSiblingTileCount=${sub.visibleSiblingTileCount})`);
      if (!sub.backButton || sub.backButton.width <= 0 || sub.backButton.height <= 0) failures.push(`subpage back button must be visible with non-zero bounds (got ${JSON.stringify(sub.backButton)})`);
    }
  }
  return failures;
}

export function parseArgs(argv) {
  const options = {
    selfTest: false, requireChrome: false, noBuild: false, customDist: false,
    distDir: path.join(windowsRoot, "dist"), outDir: null, chromeBin: process.env.CHROME_BIN || null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--self-test") options.selfTest = true;
    else if (arg === "--require-chrome") options.requireChrome = true;
    else if (arg === "--no-build") options.noBuild = true;
    else if (arg === "--dist" && i + 1 < argv.length) { options.distDir = path.resolve(argv[++i]); options.customDist = true; }
    else if (arg === "--out-dir" && i + 1 < argv.length) options.outDir = path.resolve(argv[++i]);
    else if (arg === "--chrome" && i + 1 < argv.length) options.chromeBin = argv[++i];
    else return null;
  }
  return options;
}

function runSelfTest() {
  const validStandard = {
    isNativeHost: true, isParked: false, errors: [],
    appRect: { left: 0, top: 0, right: 412, bottom: 680, width: 412, height: 680 },
    popoverRect: { left: 16, top: 16, right: 396, bottom: 664, width: 380, height: 648 },
    islands: [{ className: "win-island win-island--top", left: 16, top: 16, right: 396, bottom: 160 }, { className: "win-island win-island--bottom", left: 16, top: 170, right: 396, bottom: 664 }],
    documentElementScrollWidth: 412, chromeLabels: [{ selector: ".cc-footer-label", text: "演示环境", clientWidth: 80, scrollWidth: 80 }],
    scrollAreaHeight: 280, activeRoomId: null, subpage: null,
  };
  const passAll = evaluateSnapshot(validStandard, SCENARIOS[0]);
  if (passAll.length !== 0) { console.error("self-test failed on valid standard snapshot:", passAll); process.exit(1); }
  const hiddenZero = { width: 0, height: 0, display: "none" };
  const validSubpage = {
    ...validStandard,
    appRect: { left: 0, top: 0, right: 412, bottom: 580, width: 412, height: 580 },
    popoverRect: { left: 16, top: 16, right: 396, bottom: 564, width: 380, height: 548 },
    islands: [{ className: "win-island win-island--top", left: 16, top: 16, right: 396, bottom: 140 }, { className: "win-island win-island--bottom", left: 16, top: 150, right: 396, bottom: 564 }],
    scrollAreaHeight: 320,
    subpage: {
      mounted: true, hiddenControls: { "#command-input": hiddenZero, '.cc-room-pill[data-room-id="room_living"]': hiddenZero, ".win-slider-deck": hiddenZero },
      visibleSiblingTileCount: 0, backButton: { width: 28, height: 28 },
    },
  };
  const passSubpage = evaluateSnapshot(validSubpage, SCENARIOS[4]);
  if (passSubpage.length !== 0) { console.error("self-test failed on valid compact subpage snapshot:", passSubpage); process.exit(1); }
  const broken = {
    ...validSubpage, isParked: true,
    popoverRect: { left: 0, top: 0, right: 412, bottom: 580, width: 412, height: 580 },
    chromeLabels: [{ selector: ".cc-footer-label", text: "Truncated", clientWidth: 40, scrollWidth: 65 }],
    scrollAreaHeight: 110,
    subpage: {
      ...validSubpage.subpage, hiddenControls: { ...validSubpage.subpage.hiddenControls, "#command-input": { width: 240, height: 32, display: "block" } },
      visibleSiblingTileCount: 3, backButton: { width: 0, height: 0 },
    },
  };
  const failures = evaluateSnapshot(broken, SCENARIOS[4]);
  if (failures.length < 6) { console.error("self-test expected at least 6 failures on broken snapshot, got:", failures); process.exit(1); }
  const defaultOpts = parseArgs([]), customOpts = parseArgs(["--no-build", "--dist", "/tmp/custom-dist"]);
  if (!defaultOpts || defaultOpts.customDist !== false || defaultOpts.noBuild !== false || !customOpts || customOpts.customDist !== true || customOpts.noBuild !== true || customOpts.distDir !== path.resolve("/tmp/custom-dist")) {
    console.error("self-test failed on parseArgs customDist/noBuild flags:", { defaultOpts, customOpts }); process.exit(1);
  }
  const badCli = spawnSync(process.execPath, [scriptPath, "--unknown-flag"], { encoding: "utf8" });
  if (badCli.status !== 2 || !String(badCli.stderr ?? "").includes(usageText)) {
    console.error("self-test expected unknown flag to exit 2 with usage, got:", badCli.status, badCli.stderr); process.exit(1);
  }
  console.log("verify-flyout-layout self-test passed");
}

function findChromeBinary(explicitBin) {
  const candidates = explicitBin ? [explicitBin] : [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "msedge",
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  ];
  for (const cand of candidates) {
    if (cand.includes("/") || cand.includes("\\")) { if (fs.existsSync(cand)) return cand; }
    else {
      const probe = spawnSync(process.platform === "win32" ? "where" : "which", [cand], { encoding: "utf8" });
      if (probe.status === 0) {
        const resolved = String(probe.stdout ?? "").split(/\r?\n/).map((line) => line.trim()).find(Boolean);
        if (resolved) return resolved;
      }
    }
  }
  return null;
}

function ensureDistBuilt(options) {
  if (!options.noBuild && !options.customDist) {
    const sharedDeps = path.join(repoRoot, "scripts", "shared_windows_deps.sh");
    const build = spawnSync("bash", [sharedDeps, "run", "npm", "--prefix", windowsRoot, "run", "build"], { stdio: "inherit" });
    if (build.status !== 0) process.exit(build.status ?? 1);
  }
  if (!fs.existsSync(path.join(options.distDir, "index.html"))) {
    console.error(`❌ Missing frontend bundle at ${options.distDir}/index.html`);
    process.exit(2);
  }
}

const MIME_BY_EXT = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".json": "application/json; charset=utf-8", ".png": "image/png",
};

function startStaticServer(distDir) {
  const rootDir = path.resolve(distDir);
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const urlPath = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
      const resolved = path.resolve(rootDir, urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, ""));
      if (!resolved.startsWith(rootDir)) return res.writeHead(403).end("Forbidden");
      if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) return res.writeHead(404).end("Not found");
      res.writeHead(200, { "Content-Type": MIME_BY_EXT[path.extname(resolved).toLowerCase()] ?? "application/octet-stream" });
      res.end(fs.readFileSync(resolved));
    });
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` }));
  });
}

async function waitForPageWebSocketUrl(debugPort, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
      if (res.ok) {
        const targets = await res.json();
        const page = Array.isArray(targets) ? targets.find((t) => t.type === "page" && t.webSocketDebuggerUrl) : null;
        if (page) return page.webSocketDebuggerUrl;
      }
    } catch {}
    await new Promise((r) => setTimeout(r, 40));
  }
  throw new Error(`Timed out waiting for Chrome page target on port ${debugPort}`);
}

class CdpSession {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.errors = [];
    ws.addEventListener("message", (event) => {
      const msg = JSON.parse(typeof event.data === "string" ? event.data : String(event.data));
      if (typeof msg.id === "number") {
        const entry = this.pending.get(msg.id);
        if (!entry) return;
        this.pending.delete(msg.id);
        if (msg.error) entry.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else entry.resolve(msg.result);
        return;
      }
      if (msg.method === "Runtime.exceptionThrown") {
        const details = msg.params?.exceptionDetails;
        this.errors.push(details?.exception?.description || details?.text || "Runtime.exceptionThrown");
      } else if (msg.method === "Runtime.consoleAPICalled" && msg.params?.type === "error") {
        this.errors.push(`console.error: ${(msg.params?.args ?? []).map((a) => a.value ?? a.description ?? "").join(" ")}`);
      } else if (msg.method === "Log.entryAdded" && msg.params?.entry?.level === "error") {
        if (!String(msg.params.entry.url ?? "").endsWith("/favicon.ico")) this.errors.push(`Log.error: ${String(msg.params.entry.text ?? "")}`);
      }
    });
  }
  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { try { this.ws.close(); } catch {} }
}

async function connectCdpPage(wsUrl) {
  const ws = new globalThis.WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", (err) => reject(err), { once: true });
  });
  return new CdpSession(ws);
}

function buildInitScript(sc) {
  const settingsJson = JSON.stringify({
    connectionMode: "demo", hasCompletedOnboarding: true,
    interfaceLanguage: sc.interfaceLanguage, appearance: sc.appearance, panelHeight: sc.panelHeight,
  });
  return `window.__TAURI_INTERNALS__ = { invoke: async (cmd) => (cmd === "panel_is_visible" ? true : undefined) };
    try { localStorage.clear(); localStorage.setItem("menumijia.windows.settings.v2", ${JSON.stringify(settingsJson)}); } catch {}`;
}

function buildSnapshotExpression(sc) {
  return `(() => {
    const round = (n) => Math.round(n * 100) / 100;
    const roundRect = (el) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: round(r.left), top: round(r.top), right: round(r.right), bottom: round(r.bottom), width: round(r.width), height: round(r.height) };
    };
    const effectiveDisplay = (el) => {
      if (!el) return "missing";
      for (let cur = el; cur && cur.nodeType === 1; cur = cur.parentElement) {
        if (window.getComputedStyle(cur).display === "none") return "none";
      }
      return window.getComputedStyle(el).display;
    };
    const view = ${JSON.stringify(sc.view)};
    if (view === "room") {
      const pill = document.querySelector('.cc-room-pill[data-room-id="room_living"]');
      if (pill && !pill.classList.contains("is-active")) pill.click();
    } else if (view === "subpage") {
      const expandBtn = document.querySelector('[data-expand-device="light.living_ceiling"]');
      if (expandBtn && !document.querySelector('.cc-tile.is-subpage[data-tile-id="light.living_ceiling"]')) expandBtn.click();
    }
    const app = document.getElementById("app"), popover = document.querySelector(".cc-popover"), scrollArea = document.querySelector(".cc-scroll-area");
    const islands = Array.from(document.querySelectorAll(".win-island")).filter((el) => effectiveDisplay(el) !== "none" && el.getBoundingClientRect().height > 0).map((el) => ({ className: el.className, ...roundRect(el) }));
    const chromeLabels = [];
    for (const selector of [".cc-footer-label", ".cc-subpage-back", ".win-subpage-back"]) {
      for (const el of document.querySelectorAll(selector)) {
        const r = el.getBoundingClientRect();
        if (effectiveDisplay(el) !== "none" && r.width > 0 && r.height > 0) chromeLabels.push({ selector, text: (el.textContent || "").trim(), clientWidth: el.clientWidth, scrollWidth: el.scrollWidth });
      }
    }
    const activeRoomPill = document.querySelector(".cc-room-pill.is-active");
    let subpage = null;
    if (view === "subpage") {
      const subEl = document.querySelector('.cc-tile.is-subpage[data-tile-id="light.living_ceiling"]'), hiddenControls = {};
      for (const sel of ["#command-input", '.cc-room-pill[data-room-id="room_living"]', ".win-slider-deck"]) {
        const el = document.querySelector(sel), r = roundRect(el);
        hiddenControls[sel] = { width: r ? r.width : 0, height: r ? r.height : 0, display: el ? effectiveDisplay(el) : "none" };
      }
      const visibleSiblingTileCount = Array.from(document.querySelectorAll(".cc-scroll-area .cc-tile:not(.is-subpage)")).filter((el) => {
        const r = el.getBoundingClientRect();
        return effectiveDisplay(el) !== "none" || r.width > 0 || r.height > 0;
      }).length;
      const backBtn = document.querySelector("#btn-subpage-back, .cc-subpage-back, .win-subpage-back");
      subpage = { mounted: Boolean(subEl && effectiveDisplay(subEl) !== "none" && subEl.getBoundingClientRect().height > 0), hiddenControls, visibleSiblingTileCount, backButton: roundRect(backBtn) };
    }
    return {
      ready: Boolean(app && popover && scrollArea), isNativeHost: Boolean(app && app.classList.contains("is-native-host")),
      isParked: Boolean(app && app.classList.contains("is-parked")), appRect: roundRect(app), popoverRect: roundRect(popover), islands,
      documentElementScrollWidth: document.documentElement.scrollWidth, chromeLabels,
      scrollAreaHeight: scrollArea ? round(scrollArea.getBoundingClientRect().height) : 0,
      activeRoomId: activeRoomPill ? activeRoomPill.getAttribute("data-room-id") : null, subpage,
    };
  })()`;
}

function launchChrome(chromeBin, userDataDir) {
  const flags = [
    "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${userDataDir}`, "--no-first-run",
    "--no-default-browser-check", "--disable-gpu", "--disable-background-networking", "--disable-sync",
    "--disable-extensions", "--mute-audio", "about:blank",
  ];
  return new Promise((resolve, reject) => {
    const proc = spawn(chromeBin, flags, { stdio: ["ignore", "ignore", "pipe"] });
    let stderrBuf = "";
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for DevTools port from ${chromeBin}: ${stderrBuf}`)), 8000);
    proc.once("error", (err) => { clearTimeout(timer); reject(err); });
    proc.stderr.setEncoding("utf8");
    proc.stderr.on("data", (chunk) => {
      stderrBuf += chunk;
      const match = /DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//.exec(stderrBuf);
      if (match) { clearTimeout(timer); resolve({ proc, port: Number(match[1]) }); }
    });
    proc.once("exit", (code) => { clearTimeout(timer); reject(new Error(`Chrome exited early with code ${String(code)}: ${stderrBuf}`)); });
  });
}

async function terminateChrome(proc, tmpDir) {
  if (proc && proc.exitCode === null && !proc.killed) {
    await new Promise((resolve) => {
      const killTimer = setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} resolve(); }, 1500);
      proc.once("exit", () => { clearTimeout(killTimer); resolve(); });
      try { proc.kill("SIGTERM"); } catch { clearTimeout(killTimer); resolve(); }
    });
  }
  if (tmpDir) { try { fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); } catch {} }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options) { console.error(usageText); process.exit(2); }
  if (options.selfTest) { runSelfTest(); return; }
  const chromeBin = findChromeBinary(options.chromeBin);
  if (!chromeBin) {
    if (options.requireChrome) { console.error("❌ Chrome/Chromium/Edge binary not found (--require-chrome specified)"); process.exit(1); }
    console.log("⏭️  跳过 Windows 飞出面板无头浏览器布局校验：未找到 Chrome/Chromium/Edge");
    return;
  }
  ensureDistBuilt(options);
  const { server, origin } = await startStaticServer(options.distDir);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "mmb-flyout-cdp-"));
  let chromeProc = null, cdp = null;
  try {
    const launched = await launchChrome(chromeBin, tmpDir);
    chromeProc = launched.proc;
    cdp = await connectCdpPage(await waitForPageWebSocketUrl(launched.port));
    for (const domain of ["Runtime.enable", "Page.enable", "DOM.enable", "Log.enable"]) await cdp.send(domain);
    if (options.outDir) fs.mkdirSync(options.outDir, { recursive: true });
    let previousScriptId = null, totalFailures = 0;
    const report = [];
    for (const sc of SCENARIOS) {
      cdp.errors = [];
      if (previousScriptId) await cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: previousScriptId });
      previousScriptId = (await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: buildInitScript(sc) })).identifier;
      await cdp.send("Emulation.setDeviceMetricsOverride", { width: sc.width, height: sc.height, deviceScaleFactor: 2, mobile: false });
      await cdp.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-reduced-motion", value: "reduce" }, { name: "prefers-color-scheme", value: sc.appearance }],
      });
      await cdp.send("Page.navigate", { url: `${origin}/?scenario=${encodeURIComponent(sc.id)}` });
      let snapshot = null;
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        const evalRes = await cdp.send("Runtime.evaluate", { expression: buildSnapshotExpression(sc), returnByValue: true });
        snapshot = evalRes?.result?.value ?? null;
        if (snapshot?.ready && snapshot.popoverRect?.height > 0) break;
        await new Promise((r) => setTimeout(r, 35));
      }
      const fullSnapshot = { ...(snapshot ?? {}), errors: [...cdp.errors] };
      const failures = evaluateSnapshot(fullSnapshot, sc);
      if (failures.length > 0) {
        totalFailures += failures.length;
        console.error(`❌ [${sc.id}] failed:`);
        for (const f of failures) console.error(`   - ${f}`);
      } else {
        console.log(`✅ [${sc.id}] ${sc.width}x${sc.height} ${sc.interfaceLanguage} ${sc.appearance} (${sc.view}) scrollArea=${fullSnapshot.scrollAreaHeight}px`);
      }
      if (options.outDir) {
        const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
        if (shot?.data) fs.writeFileSync(path.join(options.outDir, `${sc.id}.png`), Buffer.from(shot.data, "base64"));
      }
      report.push({ scenario: sc, snapshot: fullSnapshot, failures });
    }
    if (options.outDir) fs.writeFileSync(path.join(options.outDir, "report.json"), JSON.stringify(report, null, 2), "utf8");
    if (totalFailures > 0) { process.exitCode = 1; return; }
    console.log(`✅ Windows 飞出面板 ${SCENARIOS.length} 组无头 Chrome CDP 布局与子页面可见性校验全部通过`);
  } finally {
    if (cdp) cdp.close();
    server.close();
    await terminateChrome(chromeProc, tmpDir);
  }
}

await main();
