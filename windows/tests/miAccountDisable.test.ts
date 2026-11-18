import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { canRefreshDevicesInBackground } from "../src/ui/appLifecycle.js";
import { getHostMiAccountsStore, refreshDevices, setHostDualSourceEnabled, setHostHAInvokeOverride } from "../src/ui/cloudRefresh.js";
import { scheduleEchoReadBack } from "../src/ui/commandDispatch.js";
import { setMiAccountEnabledOnHost } from "../src/ui/connectionsAndDiagView.js";
import { markTimerSnapshotReady, processScheduledCommands, scheduledCommandIdentity } from "../src/ui/scheduledCommands.js";
import { executeBuiltInQuickAction } from "../src/ui/speechGuard.js";
import { onOpenURL } from "../src/core/appUrlCommand.js";
import { AutomationRuleStore, createAutomationRule } from "../src/core/automationEngine.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  filterEnabledMiAccounts,
  resolveMiAccountSelectionState,
} from "../src/core/miAccountControl.js";
import { MiotSpecResolver, parseMiotDeviceSpec, type HttpRequest, type HttpResponse, type HttpTransport, type MiSession } from "../src/core/miCloudClient.js";
import { scheduleDelayedReadBack } from "../src/core/optimisticLock.js";
import { getXiaomiBackoffUntilMs, recordXiaomiRateLimit } from "../src/core/pollingPolicy.js";
import { CredentialVault, type SecureInvoke } from "../src/core/secureStore.js";

const SEC = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SESS_A: MiSession = { userId: "10001", cUserId: "c1", ssecurity: SEC, serviceToken: "tok-a", passToken: "", region: "cn" };
const SESS_B: MiSession = { userId: "20002", cUserId: "c2", ssecurity: SEC, serviceToken: "tok-b", passToken: "", region: "sg" };
const ACC_A = makeMiAccount(SESS_A).id;
const ACC_B = makeMiAccount(SESS_B).id;
const LIGHT_MODEL = "yeelink.light.lamp4";
const HEATER_PLUG_MODEL = "chuangmi.plug.v3";
const CAM_MODEL = "isa.camera.hlc7";

const LIGHT_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:light:0000A001:yeelink-lamp4:1",
  services: [{ iid: 2, type: "urn:miot-spec-v2:service:light:00007802:yeelink-lamp4:1", properties: [
    { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-lamp4:1", format: "bool", access: ["read", "write"] },
    { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-lamp4:1", format: "uint8", access: ["read", "write"], valueRange: [1, 100, 1] },
  ], actions: [] }],
})!;
const PLUG_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:outlet:0000A002:chuangmi-v3:1",
  services: [{ iid: 2, type: "urn:miot-spec-v2:service:switch:0000780C:chuangmi-v3:1", properties: [
    { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:chuangmi-v3:1", format: "bool", access: ["read", "write"] },
  ], actions: [] }],
})!;
const CAM_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:camera:0000A01C:isa-hlc7:1",
  services: [
    { iid: 2, type: "urn:miot-spec-v2:service:camera-control:0000782F:isa-hlc7:1", properties: [
      { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:isa-hlc7:1", format: "bool", access: ["read", "write"] },
    ], actions: [] },
    { iid: 9, type: "urn:miot-spec-v2:service:p2p-stream:00007881:isa-hlc7:1", properties: [], actions: [
      { iid: 1, type: "urn:miot-spec-v2:action:start-p2p-stream:00002839:isa-hlc7:1" },
      { iid: 2, type: "urn:miot-spec-v2:action:stop-stream:00002822:isa-hlc7:1" },
    ] },
  ],
})!;

const okMi = (result: unknown): HttpResponse => ({ status: 200, headers: {}, body: JSON.stringify({ code: 0, message: "ok", result }) });
const reqUser = (req: HttpRequest): string => /userId=([^;\s]+)/.exec(req.headers?.["Cookie"] ?? req.headers?.["cookie"] ?? "")?.[1] ?? "";
const reqPath = (req: HttpRequest): string => new URL(req.url).pathname.replace(/^\/(?:app\/)?/, "");

function makeSecure(): { invoke: SecureInvoke; data: Map<string, string>; tauriCalls: Array<{ cmd: string; args: Record<string, unknown> }> } {
  const data = new Map<string, string>();
  const tauriCalls: Array<{ cmd: string; args: Record<string, unknown> }> = [];
  const invoke: SecureInvoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T | null> => {
    tauriCalls.push({ cmd, args });
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") return ((data.get(name) ?? null) as unknown) as T | null;
    if (cmd === "secure_store_set") { data.set(name, String(args["value"] ?? "")); return null; }
    if (cmd === "secure_store_delete") { data.delete(name); return null; }
    if (cmd === "secure_store_list_mi_account_slots") {
      return [...data.keys()].filter((k) => k.startsWith("mi_session_")).map((k) => k.slice("mi_session_".length)) as unknown as T;
    }
    return null;
  };
  return { invoke, data, tauriCalls };
}

function mountApp(transport: HttpTransport, secure = makeSecure()): MenuMijiaWindowsApp {
  (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = {
    invoke: (cmd: string, args: Record<string, unknown> = {}) => secure.invoke(cmd, args),
  };
  const app = new MenuMijiaWindowsApp(document.getElementById("app")!);
  (app as unknown as { transport: HttpTransport }).transport = transport;
  (app as unknown as { specResolver: MiotSpecResolver }).specResolver = new MiotSpecResolver(transport, {
    [LIGHT_MODEL]: LIGHT_SPEC, [HEATER_PLUG_MODEL]: PLUG_SPEC, [CAM_MODEL]: CAM_SPEC,
  });
  (app as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secure.invoke);
  app.miAccountsStore = null;
  app.settings.hasCompletedOnboarding = true;
  app.activeSheet = "none";
  app.timerCredentialsReady = true;
  return app;
}

let dom: Window | null = null;
let removeCssEscape: (() => void) | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  removeCssEscape = installCssEscape();
  setLanguage("zh-Hans");
});

afterEach(async () => {
  removeCssEscape?.();
  if (dom) await closeTestWindow(dom);
  dom = null;
});

describe("P2a-W Xiaomi account disable & P1b integration", () => {
  it("keeps legacy accounts enabled, seals migration idempotently, and falls back on corrupted/uncertain state without sealing", () => {
    const accounts = [makeMiAccount(SESS_A), makeMiAccount(SESS_B)];
    const first = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(first.mode, "legacyPreserved");
    assert.equal(filterEnabledMiAccounts(accounts, first).length, 2);
    assert.equal(first.persistIfMigrationReady(), true);

    const rawSaved = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY)!) as Record<string, unknown>;
    assert.equal(rawSaved["migrationComplete"], true);
    rawSaved["futureField"] = "keep-me";
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify(rawSaved));

    const second = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(second.mode, "explicit");
    assert.equal(filterEnabledMiAccounts(accounts, second).length, 2);

    // Corrupted JSON falls back to legacy (all enabled) and refuses to seal migration over corruption.
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, "{not-valid-json");
    const corrupted = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(corrupted.mode, "uncertainFallback");
    assert.equal(filterEnabledMiAccounts(accounts, corrupted).length, 2);
    assert.equal(corrupted.persistIfMigrationReady(), false);
    assert.equal(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY), "{not-valid-json");

    // Partial vault read also triggers uncertainFallback without sealing migration.
    localStorage.removeItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
    const partial = resolveMiAccountSelectionState({
      storage: localStorage, accounts, hasExistingPreferences: true, identityReadFailure: "partial_mi_accounts_vault",
    });
    assert.equal(partial.mode, "uncertainFallback");
    assert.equal(partial.persistIfMigrationReady(), false);
  });

  it("shares the same enabled input across multi-account, single-source, and dual-source while stopping cloud/topology/camera/backoff", async () => {
    const calls: Array<{ user: string; path: string }> = [];
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      calls.push({ user, path });
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        const hid = user === "10001" ? "9101" : "9202";
        const dids = user === "10001" ? ["101"] : ["202", "203"];
        return okMi({ homelist: [{ id: hid, name: `Home-${user}`, roomlist: [{ id: `r-${hid}`, name: "客厅", dids }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主号台灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [
              { did: "202", name: "副号台灯", model: LIGHT_MODEL, isOnline: true },
              { did: "203", name: "副号摄像机", model: CAM_MODEL, isOnline: true, localip: "192.168.1.88" },
            ] });
      }
      if (path === "miotspec/prop/get") {
        return user === "10001"
          ? okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }])
          : okMi([
              { did: "202", siid: 2, piid: 1, code: 0, value: true }, { did: "202", siid: 2, piid: 2, code: 0, value: 50 },
              { did: "203", siid: 2, piid: 1, code: 0, value: true },
            ]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "主号台灯"), true);
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), true);

    // Simulate active camera view & rate-limit backoff on Account B, then disable Account B.
    const camDev = app.devices.find((d) => d.name === "副号摄像机")!;
    app.cameraLive.activeLiveCameraId = camDev.id;
    app.cameraLive.liveCameraKeepAliveTimer = window.setInterval(() => {}, 15_000);
    recordXiaomiRateLimit(app, SESS_B);

    calls.length = 0;
    const disableB = await setMiAccountEnabledOnHost(app, ACC_B, false);
    assert.equal(disableB.status, "applied");
    assert.equal(app.cameraLive.activeLiveCameraId, null);
    assert.equal(app.cameraLive.liveCameraKeepAliveTimer, null);
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), false);
    assert.equal(app.devices.some((d) => d.name === "主号台灯"), true);

    calls.length = 0;
    await refreshDevices(app, false);
    assert.equal(calls.some((c) => c.user === "20002"), false, "disabled Account B must issue zero requests");
    assert.equal(calls.some((c) => c.user === "10001"), true, "enabled Account A keeps refreshing");

    // Disable remaining Account A in single-source: zero Xiaomi requests and background poll disabled (`lightsOff` quick action paused via confirmPause).
    recordXiaomiRateLimit(app, SESS_A);
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(getXiaomiBackoffUntilMs(app, SESS_A), null);
    assert.equal(canRefreshDevicesInBackground(app), false);
    calls.length = 0;
    await refreshDevices(app, false);
    assert.equal(calls.length, 0);
    assert.equal(app.devices.length, 0);

    // Dual-source with HA configured while both Mi accounts remain disabled: HA refreshes, Mi issues zero calls!
    app.settings.haBaseURL = "http://homeassistant.local:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    let haCalls = 0;
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        haCalls += 1;
        return ({
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 200 } }],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          areas: [],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    await refreshDevices(app, false);
    assert.equal(haCalls, 1);
    assert.equal(calls.length, 0, "dual-source must issue zero Xiaomi requests when all Xiaomi accounts are disabled");
    assert.equal(app.devices.some((d) => d.name === "HA客厅灯"), true);
  });

  it("produces zero new requests, timers, tasks, or writes after disable across in-flight refresh, read-backs, and camera negotiation", async () => {
    let releaseRefresh!: () => void;
    let releaseSpec!: () => void;
    const refreshGate = new Promise<void>((r) => { releaseRefresh = r; });
    const specGate = new Promise<void>((r) => { releaseSpec = r; });
    const callsAfterDisable: string[] = [];
    let disabled = false;
    const secure = makeSecure();

    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (disabled) callsAfterDisable.push(path);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        await refreshGate;
        return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        await refreshGate;
        return okMi({ list: [{ did: "101", name: "书房灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 60 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.devices = [
      { id: "101", name: "书房灯", roomId: "r1", roomName: "书房", model: LIGHT_MODEL, isOnline: true, sourceBackend: "xiaomiCloud", kind: { kind: "light", entityId: "101.2.1", isOn: true, brightnessPercent: 60, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, availableEffects: [], currentEffect: null } },
      { id: "109", name: "玄关摄像机", roomId: "r1", roomName: "玄关", model: CAM_MODEL, isOnline: true, sourceBackend: "xiaomiCloud", kind: { kind: "camera", entityId: "109.2.1", isOn: true, powerWritable: true, nightShot: null, availableNightShots: [], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null, lenses: [] } },
    ];

    // 1. Start an in-flight refresh, an echo read-back timer, a delayed read-back timer, and an in-flight camera stream negotiation.
    const inFlightRefresh = refreshDevices(app, true);
    scheduleEchoReadBack(app, "101", null, 20);
    let delayedFired = false;
    scheduleDelayedReadBack(app, "101", 20, () => { delayedFired = true; });
    (app as unknown as { specResolver: { resolve: () => Promise<typeof CAM_SPEC> } }).specResolver = {
      resolve: async () => { await specGate; return CAM_SPEC; },
    };
    app.cameraLive.activeLiveCameraId = "109";
    const inFlightCam = app.cameraLive.resolveCloudCameraStream(app.devices[1]!);

    // 2. Disable the account while all four are in flight / armed.
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    disabled = true;
    const tauriCountAtDisable = secure.tauriCalls.filter((c) => c.cmd === "start_xiaomi_camera_bridge").length;

    // 3. Release in-flight Promises and wait past read-back timer delays.
    releaseRefresh();
    releaseSpec();
    await inFlightRefresh;
    await inFlightCam;
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(callsAfterDisable, [], "zero network requests after disable");
    assert.equal(delayedFired, false, "delayed read-back timer cancelled on disable");
    assert.equal(secure.tauriCalls.filter((c) => c.cmd === "start_xiaomi_camera_bridge").length, tauriCountAtDisable, "late camera negotiation must not start bridge");
    assert.equal(app.devices.length, 0, "late refresh result must not repopulate devices");
    assert.equal(app.settings.cachedXiaomiDevices.length, 0);
  });

  it("previews affected timers/automations/quickActions, pauses on confirm, and revalidates on re-enable without auto-firing expired timers", async () => {
    let activeDids = ["101", "102"];
    const writes: string[] = [];
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") writes.push(path);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({
          list: activeDids.map((did) => ({
            did, name: did === "101" ? "书房台灯" : "备用台灯", model: LIGHT_MODEL, isOnline: true,
          })),
        });
      }
      if (path === "miotspec/prop/get") {
        return okMi(activeDids.flatMap((did) => [
          { did, siid: 2, piid: 1, code: 0, value: true },
          { did, siid: 2, piid: 2, code: 0, value: 70 },
        ]));
      }
      return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const nowMs = 1_700_000_000_000;
    const idA = scheduledCommandIdentity(app.settings)!;
    const foreignId = JSON.stringify(["xiaomiCloud", "10001", "cn"]);
    void foreignId;
    const queueA = app.scheduledCommandStore.queue(idA);
    queueA.scheduledCommands = [
      { id: "timer_expire", command: "关书房台灯", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "timer_future", command: "调亮书房台灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "brightness", percent: 90 } }] },
      { id: "timer_deleted", command: "关备用台灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "102", operation: { kind: "power", isOn: false } }] },
    ];
    queueA.missedScheduledCommands = [
      { id: "timer_missed", command: "早先错过", reply: "好", delaySeconds: 30, fireTimestampMs: nowMs - 10_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    // Foreign timer owned by Account B when we also test foreign partition:
    const queueB = app.scheduledCommandStore.queue(JSON.stringify(["xiaomiCloud", "20002", "sg"]));
    queueB.scheduledCommands = [
      { id: "timer_foreign_b", command: "关副号灯", reply: "好", delaySeconds: 120, fireTimestampMs: nowMs + 120_000, intents: [{ targetId: "202", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "rule_on", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "rule_user_off", isEnabled: false, trigger: "screenUnlocked", action: { kind: "devices", deviceIds: ["101"], isOn: true } }),
    ]);

    // 1. Preview without confirmation -> requiresPauseConfirmation, account stays enabled!
    const preview = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(preview.status, "requiresPauseConfirmation");
    if (preview.status === "requiresPauseConfirmation") {
      const kinds = new Set(preview.verdict.itemsToPause.map((i) => `${i.kind}:${i.id}`));
      assert.equal(kinds.has("waitingTimer:timer_expire"), true, `items=${[...kinds].join(",")}`);
      assert.equal(kinds.has("missedTimer:timer_missed"), true, `items=${[...kinds].join(",")}`);
      assert.equal(kinds.has("automationRule:rule_on"), true, `items=${[...kinds].join(",")}`);
      assert.equal(kinds.has("automationRule:rule_user_off"), false, `items=${[...kinds].join(",")}`);
      assert.equal(kinds.has("quickAction:lightsOff"), true, `items=${[...kinds].join(",")}`);
    }
    assert.equal(app.devices.length, 2, "account stays active before confirmation");

    // 2. Confirm pause -> pauses timers, enabled rule, and quickAction; zero executions while paused!
    const confirmed = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(confirmed.status, "applied");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "rule_on")?.isEnabled, false);

    processScheduledCommands(app, nowMs + 120_000);
    await executeBuiltInQuickAction(app, "lightsOff");
    assert.deepEqual(writes, [], "paused timers and quick actions must issue zero writes while disabled");

    // 3. Remove device 102 upstream and re-enable at nowMs + 120_000 (so timer_expire is expired, timer_future is still future, timer_deleted lost target 102).
    activeDids = ["101"];
    const reenabled = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 120_000 });
    assert.equal(reenabled.status, "applied");
    assert.deepEqual(writes, [], "expired paused timer must never auto-execute on re-enable");
    assert.deepEqual(app.scheduledCommands.map((t) => t.id), ["timer_future"]);
    assert.deepEqual(
      new Set(app.missedScheduledCommands.map((t) => t.id)),
      new Set(["timer_missed", "timer_expire", "timer_deleted"]),
    );
    assert.equal(ruleStore.load().find((r) => r.id === "rule_on")?.isEnabled, true, "capability-paused rule resumes");
    assert.equal(ruleStore.load().find((r) => r.id === "rule_user_off")?.isEnabled, false, "user-disabled rule stays off");
  });

  it("gates control writes before confirmation and distinguishes disabled Xiaomi account from nonexistent device", async () => {
    const writes: string[] = [];
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") writes.push(path);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [
          { did: "101", name: "书房台灯", model: LIGHT_MODEL, isOnline: true },
          { did: "105", name: "电暖器插座", model: HEATER_PLUG_MODEL, isOnline: true },
        ] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([
          { did: "101", siid: 2, piid: 1, code: 0, value: false },
          { did: "101", siid: 2, piid: 2, code: 0, value: 50 },
          { did: "105", siid: 2, piid: 1, code: 0, value: false },
        ]);
      }
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await refreshDevices(app, false);
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });

    // High-risk heater plug 105 on disabled account: rejected before confirmation with account-disabled message!
    const okDisabled = await app.executeIntents(
      [{ targetId: "105", operation: { kind: "power", isOn: true } }],
      "打开电暖器插座",
      "测试",
    );
    assert.equal(okDisabled, false);
    assert.equal(app.pendingHighRisk, null);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.deepEqual(writes, []);

    // Nonexistent device 999404: rejected as 设备不存在!
    const okMissing = await app.executeIntents(
      [{ targetId: "999404", operation: { kind: "power", isOn: true } }],
      "打开不存在设备",
      "测试",
    );
    assert.equal(okMissing, false);
    assert.match(app.replyBanner?.text ?? "", /设备不存在/);

    // Direct applyCommand & URL scheme also reject disabled account vs missing device with zero writes.
    const cmdOk = await app.applyCommand({ kind: "setLightPower", entityId: "101.2.1", isOn: true });
    assert.equal(cmdOk, false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);

    setLanguage("en");
    const cmdEn = await app.applyCommand({ kind: "setLightPower", entityId: "101.2.1", isOn: true });
    assert.equal(cmdEn, false);
    assert.match(app.replyBanner?.text ?? "", /This Xiaomi account is turned off/);
    setLanguage("zh-Hans");

    const urlToasts: string[] = [];
    await onOpenURL("menumijia://power?device=101&state=on", {
      get devices() { return app.devices; },
      get scenes() { return app.scenes; },
      get settings() { return app.settings; },
      get layout() { return app.layout; },
      get sourceRevision() { return app.sourceRevision; },
      pendingHighRisk: null,
      replyBanner: null,
      pendingConsent: null,
      expandedDeviceId: null,
      isControlBlockedByScreenLock: async () => false,
      getActiveRaycastBridgeToken: () => undefined,
      revealPanelForExternalUrl: async () => {},
      requestExternalUrlConfirmation: async () => true,
      setPendingHighRisk: () => {},
      clearPendingHighRisk: () => {},
      showExternalToast: (msg) => { urlToasts.push(msg); },
      recordRaycastCommandFeedback: () => {},
      executeSingleCommand: (d, c, s, i, r) => app.executeSingleCommand(d, c, s, i, r),
      applyCommand: (c, r) => app.applyCommand(c, r),
      updateUndoCommandsForDevice: () => {},
      handleNaturalCommand: (u, f) => app.handleNaturalCommand(u, f),
      executeBuiltInSceneFromUrl: async () => ({ message: "", isError: false }),
      focusDeviceFromUrl: () => "focused",
    });
    assert.match(urlToasts.at(-1) ?? "", /该米家账号已停用/);
    assert.deepEqual(writes, []);
  });

  it("renders minimal 连接 toggle and pause confirmation preview in Settings", async () => {
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") return okMi({ list: [{ did: "101", name: "书房台灯", model: LIGHT_MODEL, isOnline: true }] });
      if (path === "miotspec/prop/get") return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }]);
      return okMi({});
    };
    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    app.scheduledCommands = [
      { id: "t_ui", command: "关灯", reply: "好", delaySeconds: 300, fireTimestampMs: Date.now() + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();

    app.openSettingsSheet("connection");
    const connPanel = document.querySelector<HTMLElement>('[data-settings-panel="connection"]')!;
    assert.match(connPanel.textContent ?? "", /连接/);
    const toggle = connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`);
    assert.ok(toggle, "expected per-account enable switch");
    assert.equal(toggle.checked, true);

    toggle.checked = false;
    toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));

    const previewBox = connPanel.querySelector<HTMLElement>(`[data-mi-account-pause-preview="${ACC_A}"]`);
    assert.ok(previewBox, "expected pause confirmation preview");
    assert.match(previewBox.textContent ?? "", /暂停这些项并关闭/);

    // Cancel keeps account enabled
    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-cancel-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)?.checked, true);

    // Trigger again and confirm pause & disable
    const toggle2 = connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)!;
    toggle2.checked = false;
    toggle2.dispatchEvent(new window.Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));
    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-confirm-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));

    assert.equal(connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)?.checked, false);
    assert.equal(app.devices.length, 0);
    assert.equal(app.scheduledCommands.length, 0);
  });
});
