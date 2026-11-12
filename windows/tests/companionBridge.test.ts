import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand, SmartDevice } from "../src/core/models.js";
import {
  AppURLParser,
  BuiltInURLScene,
  URLDirectControl,
  onOpenURL,
} from "../src/core/appUrlCommand.js";
import {
  RaycastBridgeTokenManager,
  SNAPSHOT_SCHEMA_VERSION,
  buildRaycastSnapshot,
  formatDynamicTraySummary,
  type RaycastSnapshot,
} from "../src/core/raycastSnapshot.js";
import {
  clearUndoHoverPause,
  enqueueIncomingOpenUrl,
  getActiveRaycastBridgeTokenForHost,
  getLatestRaycastSnapshotForHost,
  runWithScheduledTimerTickExemption,
  setRaycastIntegrationEnabled,
} from "../src/ui/speechGuard.js";
import { renderReleaseNotesMarkdown } from "../src/ui/settingsViews.js";
import { confirmMissedScheduledCommand, processScheduledCommands } from "../src/ui/scheduledCommands.js";

interface TauriCall {
  readonly cmd: string;
  readonly args?: Record<string, unknown>;
}

let dom: Window;
let tauriCalls: TauriCall[] = [];
let workstationLocked = false;
let failLaunchAtLogin = false;
let pendingStartupUrls: string[] = [];

function installTauriStub(): void {
  tauriCalls = [];
  workstationLocked = false;
  failLaunchAtLogin = false;
  pendingStartupUrls = [];
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (cmd: string, args?: Record<string, unknown>) => {
      tauriCalls.push({ cmd, args });
      if (cmd === "is_workstation_locked") {
        return workstationLocked;
      }
      if (cmd === "set_launch_at_login" && failLaunchAtLogin) {
        throw new Error("registry write denied");
      }
      if (cmd === "drain_pending_open_urls") {
        const drained = [...pendingStartupUrls];
        pendingStartupUrls = [];
        return drained;
      }
      return null;
    },
  };
}

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
}

function field(selector: string): HTMLInputElement {
  return element(selector) as HTMLInputElement;
}

async function flushAsync(): Promise<void> {
  await setImmediate();
  await setImmediate();
  await setImmediate();
}

function startDemoApp(extraSettings: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...extraSettings,
    }),
  );
  return new MenuMijiaWindowsApp(element("#app"));
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  installTauriStub();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  await closeTestWindow(dom);
});

describe("RaycastSnapshot exporter & bridgeToken lifecycle", () => {
  it("exports schemaVersion 1 snapshot passing raycast validateSnapshot and rotates bridgeToken on disable", async () => {
    assert.equal(typeof onOpenURL, "function");
    const app = startDemoApp({ enableRaycastIntegration: true });
    await flushAsync();

    const firstToken = getActiveRaycastBridgeTokenForHost(app);
    assert.ok(firstToken && /^[0-9a-f]{64}$/.test(firstToken), "32-byte hex bridgeToken generated");

    // Token remains stable across refreshes while integration stays enabled.
    const sameToken = getActiveRaycastBridgeTokenForHost(app);
    assert.equal(sameToken, firstToken);

    const writeCall = tauriCalls.find((c) => c.cmd === "write_raycast_snapshot");
    assert.ok(writeCall, "write_raycast_snapshot invoked on startup when enabled");
    const written = JSON.parse(String(writeCall.args?.contents ?? "{}")) as RaycastSnapshot;

    assert.equal(written.schemaVersion, SNAPSHOT_SCHEMA_VERSION);
    assert.equal(written.connectionMode, "demo");
    assert.equal(written.bridgeToken, firstToken);
    assert.ok(typeof written.generatedAt === "string" && written.generatedAt.length > 0);
    assert.ok(typeof written.updatedAt === "string" && written.updatedAt.length > 0);
    assert.ok(Array.isArray(written.devices) && written.devices.length > 0);
    assert.ok(Array.isArray(written.quickActions) && written.quickActions.length >= 4);
    assert.ok(Array.isArray(written.scenes));
    assert.ok(Array.isArray(written.environmentReadings) && written.environmentReadings.length > 0);

    // Must satisfy Raycast extension's strict runtime validator cleanly.
    const raycastValidatorModule = (await import(
      new URL("../../raycast/src/snapshot-validation.ts", import.meta.url).href
    )) as { validateSnapshot: (parsed: unknown, path: string) => RaycastSnapshot };
    const validated = raycastValidatorModule.validateSnapshot(written, "raycast-snapshot.json");
    assert.equal(validated.schemaVersion, 1);
    assert.equal(validated.bridgeToken, firstToken);

    // Turning off Raycast integration immediately deletes snapshot and revokes/rotates token (Coding Standard #3).
    setRaycastIntegrationEnabled(app, false);
    await flushAsync();
    assert.equal(getActiveRaycastBridgeTokenForHost(app), undefined);
    assert.ok(
      tauriCalls.some((c) => c.cmd === "remove_raycast_snapshot"),
      "remove_raycast_snapshot invoked immediately when toggled off",
    );

    setRaycastIntegrationEnabled(app, true);
    await flushAsync();
    const rotatedToken = getActiveRaycastBridgeTokenForHost(app);
    assert.ok(rotatedToken && rotatedToken !== firstToken, "re-enabling issues a fresh bridgeToken");
  });

  it("manages RaycastBridgeTokenManager state cleanly in isolation", () => {
    const manager = new RaycastBridgeTokenManager();
    assert.equal(manager.getOrCreate(false), undefined);
    const tok1 = manager.getOrCreate(true);
    assert.ok(tok1 && tok1.length === 64);
    assert.equal(manager.getOrCreate(true), tok1);
    manager.revoke();
    assert.equal(manager.active, undefined);
    const tok2 = manager.getOrCreate(true);
    assert.notEqual(tok2, tok1);

    const emptySnap = buildRaycastSnapshot({
      connectionMode: "demo",
      selectedHomeId: "home_1",
      connectionSummary: "演示家庭",
      bridgeToken: tok2!,
      isStale: false,
      devices: [],
      rooms: [],
      scenes: [],
      environmentReadings: [],
    });
    assert.equal(emptySnap.selectedHomeId, "home_1");
    assert.equal(emptySnap.schemaVersion, 1);
  });
});

describe("AppURLParser, BuiltInURLScene & URLDirectControl", () => {
  it("parses all 9 menumijia:// routes, preserves literal '+', and enforces strict bounds", () => {
    const token = "a".repeat(64);
    assert.deepEqual(AppURLParser.parseEnvelope(`menumijia://toggle?device=dev_1&id=req_1&token=${token}`), {
      command: { kind: "toggle", deviceId: "dev_1" },
      requestId: "req_1",
      token,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://scene?name=quick%3AlightsOff"), {
      kind: "scene",
      name: "quick:lightsOff",
    });
    assert.deepEqual(AppURLParser.parse("menumijia://ask?text=24%2B1%20degrees"), {
      kind: "ask",
      text: "24+1 degrees",
    });
    assert.deepEqual(AppURLParser.parse("menumijia://power?device=dev_1&on=false"), {
      kind: "power",
      deviceId: "dev_1",
      isOn: false,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://brightness?device=dev_1&percent=65"), {
      kind: "brightness",
      deviceId: "dev_1",
      percent: 65,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://color-temp?device=dev_1&kelvin=4200"), {
      kind: "colorTemp",
      deviceId: "dev_1",
      kelvin: 4200,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://temperature?device=dev_ac&celsius=25.5"), {
      kind: "temperature",
      deviceId: "dev_ac",
      celsius: 25.5,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://temperature?device=dev_wh&celsius=75"), {
      kind: "temperature",
      deviceId: "dev_wh",
      celsius: 75,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://fan?device=dev_fan&percent=80"), {
      kind: "fan",
      deviceId: "dev_fan",
      percent: 80,
      preset: null,
    });
    assert.deepEqual(AppURLParser.parse("menumijia://fan?device=dev_fan&preset=%E8%87%AA%E7%84%B6%E9%A3%8E"), {
      kind: "fan",
      deviceId: "dev_fan",
      percent: null,
      preset: "自然风",
    });
    assert.deepEqual(AppURLParser.parse("menumijia://focus?device=dev_1"), {
      kind: "focus",
      deviceId: "dev_1",
    });

    // Reject out-of-range, ambiguous, or malformed URLs.
    assert.equal(AppURLParser.parse("https://example.com/toggle?device=dev_1"), null);
    assert.equal(AppURLParser.parse("menumijia://brightness?device=dev_1&percent=101"), null);
    assert.equal(AppURLParser.parse("menumijia://color-temp?device=dev_1&kelvin=500"), null);
    assert.equal(AppURLParser.parse("menumijia://temperature?device=dev_1&celsius=101"), null);
    assert.equal(AppURLParser.parse("menumijia://fan?device=dev_fan&percent=50&preset=Auto"), null);
    assert.equal(AppURLParser.parse("menumijia://fan?device=dev_fan"), null);
    assert.equal(AppURLParser.parse(`menumijia://ask?text=${"x".repeat(501)}`), null);

    // Built-in scene resolution & constant-time bridgeToken check.
    assert.equal(BuiltInURLScene.resolve("quick:lightsOff"), "lightsOff");
    assert.equal(BuiltInURLScene.resolve("柔和夜灯"), "softNightLight");
    assert.equal(BuiltInURLScene.resolve("一键全关"), "allOff");
    assert.equal(BuiltInURLScene.resolve("撤销"), "undo");

    assert.equal(URLDirectControl.isValidBridgeToken(token, token), true);
    assert.equal(URLDirectControl.isValidBridgeToken("short", "short"), false);
    assert.equal(URLDirectControl.isValidBridgeToken(token, "b".repeat(64)), false);
  });
});

describe("menumijia:// execution, confirmation lifecycle & high-risk guard", () => {
  it("executes low-risk command with valid bridgeToken and writes lastCommandFeedback", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: false });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;

    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    assert.ok(light, "demo home has an online light");
    const beforeOn = light.kind.kind === "light" ? light.kind.isOn : false;

    tauriCalls = [];
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=${encodeURIComponent(light.id)}&on=${!beforeOn}&id=req_ok_1&token=${token}`,
    );
    await flushAsync();

    assert.equal(document.querySelector(".cc-prompt"), null, "valid bridgeToken skips URL prompt");
    const updated = app.devices.find((d) => d.id === light.id)!;
    assert.equal(updated.kind.kind === "light" ? updated.kind.isOn : beforeOn, !beforeOn);

    const latest = getLatestRaycastSnapshotForHost(app);
    assert.equal(latest.lastCommandFeedback?.requestId, "req_ok_1");
    assert.equal(latest.lastCommandFeedback?.isError, false);
    assert.ok(
      tauriCalls.some((c) => c.cmd === "write_raycast_snapshot"),
      "lastCommandFeedback exported immediately",
    );
  });

  it("prompts on untokened external URL, clears on backend switch / panel hide, and runs once on confirm", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: false });
    await flushAsync();
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const initialOn = light.kind.kind === "light" ? light.kind.isOn : false;

    // 1) Missing token shows confirmation dialog and clears cleanly on backend switch / clearUndoHoverPause (§13).
    const firstRun = enqueueIncomingOpenUrl(
      app,
      `menumijia://toggle?device=${encodeURIComponent(light.id)}&id=req_cancel_switch`,
    );
    await flushAsync();
    assert.ok(document.querySelector(".cc-prompt"), "external URL confirmation prompt shown");

    clearUndoHoverPause(app);
    app.render();
    await firstRun;
    await flushAsync();
    assert.equal(document.querySelector(".cc-prompt"), null, "prompt cleared on backend reset");
    assert.equal(
      app.devices.find((d) => d.id === light.id)?.kind.kind === "light"
        ? (app.devices.find((d) => d.id === light.id)!.kind as { isOn: boolean }).isOn
        : initialOn,
      initialOn,
      "cancelled URL did not toggle device",
    );
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.requestId, "req_cancel_switch");
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.isError, true);

    // 2) Clicking #btn-url-confirm-run executes once.
    const secondRun = enqueueIncomingOpenUrl(
      app,
      `menumijia://toggle?device=${encodeURIComponent(light.id)}&id=req_confirm_1`,
    );
    await flushAsync();
    element("#btn-url-confirm-run").click();
    await secondRun;
    await flushAsync();

    const afterConfirm = app.devices.find((d) => d.id === light.id)!;
    assert.equal(afterConfirm.kind.kind === "light" ? afterConfirm.kind.isOn : initialOn, !initialOn);
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.requestId, "req_confirm_1");
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.isError, false);
  });

  it("still enforces ManualControlPolicy high-risk confirmation even with a valid bridgeToken", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: true });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;

    const plug = app.devices.find((d) => d.kind.kind === "plug" && d.isOnline)!;
    assert.ok(plug, "demo home has an online smart plug");
    // Ensure the plug starts OFF so turning it ON triggers ManualControlPolicy hazard confirmation.
    const idx = app.devices.findIndex((d) => d.id === plug.id);
    if (plug.kind.kind === "plug" && plug.kind.isOn) {
      app.devices[idx] = { ...plug, kind: { ...plug.kind, isOn: false } };
    }

    await enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=${encodeURIComponent(plug.id)}&on=true&id=req_plug_risk&token=${token}`,
    );
    await flushAsync();

    // Plug power-on requires ManualControlPolicy confirmation; first dispatch arms pendingHighRisk instead of turning on!
    const plugAfterFirst = app.devices.find((d) => d.id === plug.id)!;
    assert.equal(
      plugAfterFirst.kind.kind === "plug" ? plugAfterFirst.kind.isOn : true,
      false,
      "high-risk plug did not actuate without second confirmation",
    );
    assert.equal(app.pendingHighRisk?.deviceId, plug.id);
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.requestId, "req_plug_risk");
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.isError, true);
  });

  it("focuses a device without confirmation via menumijia://focus", async () => {
    const app = startDemoApp({ enableRaycastIntegration: false, allowDirectURLControl: false });
    await flushAsync();
    const target = app.devices.find((d) => d.kind.kind === "climate") ?? app.devices[0]!;

    window.dispatchEvent(
      new window.CustomEvent("menumijia:open-url", {
        detail: `menumijia://focus?device=${encodeURIComponent(target.id)}`,
      }),
    );
    await flushAsync();

    assert.equal(app.expandedDeviceId, target.id);
    assert.equal(app.panelSearch.selectedDeviceId, target.id);
  });

  it("enforces fan percentage / preset parity, temperature step-snapping, color-temp clamping, cover power direction, and sensor focus", async () => {
    const app = startDemoApp({ enableRaycastIntegration: true, allowDirectURLControl: true });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;

    // 1) Fan percent=60 sends setFanPercentage, not setFanPresetMode
    const fan = app.devices.find((d) => d.kind.kind === "fan" && d.isOnline)!;
    assert.ok(fan, "demo home has fan");
    const fanCommands: DeviceCommand[] = [];
    const origApplyCommand = app.applyCommand.bind(app);
    app.applyCommand = async (cmd) => {
      fanCommands.push(cmd);
      return origApplyCommand(cmd);
    };

    await enqueueIncomingOpenUrl(
      app,
      `menumijia://fan?device=${encodeURIComponent(fan.id)}&percent=60&token=${token}`,
    );
    await flushAsync();
    assert.ok(
      fanCommands.some((c) => c.kind === "setFanPercentage" && (c as { percent: number }).percent === 60),
      "fan percent=60 sends setFanPercentage",
    );
    assert.equal(
      fanCommands.some((c) => c.kind === "setFanPresetMode" && (c as { presetMode: string }).presetMode === "60"),
      false,
      "does not send literal presetMode 60",
    );

    // 2) Fan preset matches case-insensitively
    fanCommands.length = 0;
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://fan?device=${encodeURIComponent(fan.id)}&preset=level%201&token=${token}`,
    );
    await flushAsync();
    assert.ok(
      fanCommands.some((c) => c.kind === "setFanPresetMode"),
      "fan preset dispatches setFanPresetMode",
    );

    // 3) Temperature step-snapping (25.3 -> 25.5 on step 0.5)
    const climate = app.devices.find((d) => d.kind.kind === "climate" && d.isOnline)!;
    assert.ok(climate, "demo home has climate");
    const climateCommands: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      climateCommands.push(cmd);
      return origApplyCommand(cmd);
    };
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://temperature?device=${encodeURIComponent(climate.id)}&celsius=25.3&token=${token}`,
    );
    await flushAsync();
    const tempCmd = climateCommands.find((c) => c.kind === "setClimateTemperature");
    assert.ok(tempCmd, "setClimateTemperature dispatched");
    assert.equal((tempCmd as { temperature: number }).temperature, 25.5, "snapped 25.3 to 25.5");

    // 4) Color-temp clamping
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    assert.ok(light, "demo home has light");
    const lightCommands: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      lightCommands.push(cmd);
      return origApplyCommand(cmd);
    };
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://color-temp?device=${encodeURIComponent(light.id)}&kelvin=2000&token=${token}`,
    );
    await flushAsync();
    const ctCmd = lightCommands.find((c) => c.kind === "setLightColorTemp");
    assert.ok(ctCmd, "setLightColorTemp dispatched");
    const spec = light.kind as { minKelvin: number; maxKelvin: number };
    assert.equal((ctCmd as { kelvin: number }).kelvin, spec.minKelvin, "clamped to minKelvin");

    // 5) Cover power?on=false while opening sends closeDescription (not pauseDescription!)
    const cover: SmartDevice = {
      id: "cover.living_curtain",
      name: "客厅窗帘",
      roomId: "r1",
      roomName: "客厅",
      model: "lumi.curtain.acn002",
      isOnline: true,
      kind: {
        kind: "cover",
        subtype: "curtain",
        entityId: "cover.living_curtain",
        positionPercent: 40,
        positionWritable: false,
        openDescription: "open",
        closeDescription: "close",
        pauseDescription: "pause",
        batteryPercent: 100,
        faultText: null,
        motion: "opening",
      },
    };
    app.devices.push(cover);
    const coverCommands: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      coverCommands.push(cmd);
      return origApplyCommand(cmd);
    };
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=${encodeURIComponent(cover.id)}&on=false&token=${token}`,
    );
    await flushAsync();
    const coverCmd = coverCommands.find((c) => c.kind === "setSelectOption");
    assert.ok(coverCmd, "cover command sent");
    assert.equal(
      (coverCmd as { option: string }).option,
      (cover.kind as { closeDescription: string }).closeDescription,
      "closing while opening sends closeDescription, not pause",
    );

    // 6) Focus on a sensor card leaves expandedDeviceId === null (hasDetailDrawer === false)
    const sensor = app.devices.find((d) => d.kind.kind === "sensor")!;
    assert.ok(sensor, "demo home has sensor");
    app.expandedDeviceId = "something_else";
    window.dispatchEvent(
      new window.CustomEvent("menumijia:open-url", {
        detail: `menumijia://focus?device=${encodeURIComponent(sensor.id)}`,
      }),
    );
    await flushAsync();
    assert.equal(app.expandedDeviceId, null, "sensor card has no detail drawer so expandedDeviceId is null");
  });
});

describe("Desktop shell polish: Lock-screen guard, Launch at Login, Tray tooltip & Updater UI", () => {
  it("blocks manual and bridgeToken URL controls while workstation is locked, but exempts scheduled timer ticks", async () => {
    const app = startDemoApp({
      enableRaycastIntegration: true,
      blockControlWhileLocked: true,
    });
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const initialOn = light.kind.kind === "light" ? light.kind.isOn : false;

    workstationLocked = true;

    // 1) Manual command is blocked while locked.
    await app.executeSingleCommand(
      light,
      { kind: "setLightPower", entityId: light.id, isOn: !initialOn },
      "测试开关",
      { targetId: light.id, operation: { kind: "power", isOn: !initialOn } },
    );
    assert.equal(
      (app.devices.find((d) => d.id === light.id)!.kind as { isOn: boolean }).isOn,
      initialOn,
      "manual command blocked while locked",
    );
    assert.match(app.replyBanner?.text ?? "", /屏幕已锁定/);

    // 2) URL command with valid bridgeToken is ALSO blocked while locked.
    await enqueueIncomingOpenUrl(
      app,
      `menumijia://power?device=${encodeURIComponent(light.id)}&on=${!initialOn}&id=req_locked&token=${token}`,
    );
    await flushAsync();
    assert.equal(
      (app.devices.find((d) => d.id === light.id)!.kind as { isOn: boolean }).isOn,
      initialOn,
      "URL command blocked while locked",
    );
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.requestId, "req_locked");
    assert.equal(getLatestRaycastSnapshotForHost(app).lastCommandFeedback?.isError, true);

    // 3) Clicking "Run Now" on a missed timer is blocked while locked and retains the missed entry.
    const missedItem = {
      id: "missed_1",
      command: `关闭${light.name}`,
      delaySeconds: 60,
      fireTimestampMs: Date.now() - 120_000,
      reply: "已错过",
      intents: [{ targetId: light.id, operation: { kind: "power" as const, isOn: !initialOn } }],
    };
    app.missedScheduledCommands = [missedItem];
    confirmMissedScheduledCommand(app, "missed_1");
    await flushAsync();
    assert.equal(
      (app.devices.find((d) => d.id === light.id)!.kind as { isOn: boolean }).isOn,
      initialOn,
      "missed timer Run Now blocked while locked",
    );
    assert.equal(app.missedScheduledCommands.length, 1, "missed timer kept in queue while locked");

    // 4) Due timer firing on schedule in startTimerLoop stays exempt while workstation is locked!
    const nowMs = Date.now();
    app.scheduledCommands = [
      {
        id: "due_1",
        command: `切换${light.name}`,
        delaySeconds: 10,
        fireTimestampMs: nowMs - 500,
        reply: "定时触发",
        intents: [{ targetId: light.id, operation: { kind: "power" as const, isOn: !initialOn } }],
      },
    ];
    runWithScheduledTimerTickExemption(() => processScheduledCommands(app, nowMs));
    await flushAsync();
    assert.equal(
      (app.devices.find((d) => d.id === light.id)!.kind as { isOn: boolean }).isOn,
      !initialOn,
      "scheduled timer tick executes even while workstation is locked",
    );
  });

  it("toggles Launch at Login via Tauri immediately and rolls back on failure, updates dynamic tray tooltip", async () => {
    const app = startDemoApp();
    await flushAsync();

    const tooltipCall = tauriCalls.find((c) => c.cmd === "set_tray_tooltip");
    assert.ok(tooltipCall, "dynamic tray tooltip synced on render");
    const expectedSummary = formatDynamicTraySummary(app.computedEnvironmentReadings, app.devices);
    assert.equal(tooltipCall.args?.summary, expectedSummary);
    assert.ok(expectedSummary && expectedSummary.includes("°C"));

    element("#btn-settings").click();
    await flushAsync();

    const launchInput = field("#settings-launch-at-login");
    assert.equal(launchInput.checked, false);

    // Toggle ON -> invokes set_launch_at_login(true).
    tauriCalls = [];
    launchInput.checked = true;
    launchInput.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushAsync();
    assert.equal(app.settings.launchAtLogin, true);
    assert.deepEqual(
      tauriCalls.find((c) => c.cmd === "set_launch_at_login")?.args,
      { enabled: true },
    );

    // Simulate OS error -> rolls back setting and surfaces error banner.
    failLaunchAtLogin = true;
    field("#settings-launch-at-login").checked = false;
    field("#settings-launch-at-login").dispatchEvent(new window.Event("change", { bubbles: true }));
    await flushAsync();
    assert.equal(app.settings.launchAtLogin, true, "rolled back on registry write failure");
    assert.equal(app.replyBanner?.isError, true);
  });

  it("renders streaming update download progress and XSS-safe Markdown release notes", async () => {
    const html = renderReleaseNotesMarkdown(
      [
        "## 新功能",
        "- 支持 `menumijia://` **外部链接** 控制",
        "- 拦截 `<script>alert(1)</script>` 与 <img src=x onerror=alert(1)>",
        "",
        "普通说明段落",
      ].join("\n"),
    );
    assert.ok(html.includes('<h5 class="cc-md-heading">新功能</h5>'));
    assert.ok(html.includes("<code>menumijia://</code>"));
    assert.ok(html.includes("<strong>外部链接</strong>"));
    assert.ok(!html.includes("<script>"), "raw <script> tag must be escaped");
    assert.ok(!html.includes("<img "), "raw <img> tag must be escaped");
    assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));

    const app = startDemoApp();
    app.availableUpdate = {
      version: "9.9.0",
      tag: "v9.9.0",
      htmlURL: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v9.9.0",
      notes: "### 更新项\n- 分块进度显示",
      installerAsset: {
        name: "MenuBarHome_9.9.0_x64-setup.exe",
        downloadUrl: "https://github.com/jryang2026-code/MenuBarHome/releases/download/v9.9.0/setup.exe",
        sizeBytes: 10 * 1024 * 1024,
        manifestUrl: "https://github.com/jryang2026-code/MenuBarHome/releases/download/v9.9.0/manifest.json",
      },
    };
    app.isInstallingUpdate = true;
    app.activeSheet = "settings";
    app.settingsTab = "system";
    app.render();

    window.dispatchEvent(
      new window.CustomEvent("menumijia:update-progress", {
        detail: {
          downloadedBytes: 5 * 1024 * 1024,
          totalBytes: 10 * 1024 * 1024,
          bytesPerSec: 2.5 * 1024 * 1024,
        },
      }),
    );
    await flushAsync();

    const progressWrap = element("[data-update-progress]");
    const bar = progressWrap.querySelector("progress");
    assert.equal(bar?.getAttribute("value"), "50");
    assert.match(progressWrap.textContent ?? "", /5\.0 MB \/ 10\.0 MB \(50%\)/);
    assert.match(progressWrap.textContent ?? "", /2\.5 MB\/s/);
    assert.ok(element(".cc-update-notes").querySelector("ul.cc-md-list"));
  });
});
