import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { canRefreshDevicesInBackground, signOutXiaomiAccount } from "../src/ui/appLifecycle.js";
import {
  buildHostCapabilityContext,
  getHostMiAccountsStore,
  recomputeHostDualSource,
  refreshDevices,
  setHostDeviceSourcePin,
  setHostDualSourceEnabled,
  setHostHAInvokeOverride,
} from "../src/ui/cloudRefresh.js";
import { scheduleEchoReadBack } from "../src/ui/commandDispatch.js";
import { addOrUpdateMiAccountOnHost, setMiAccountEnabledOnHost } from "../src/ui/connectionsAndDiagView.js";
import {
  enqueueScheduledCommand,
  markTimerSnapshotReady,
  processScheduledCommands,
  scheduledCommandIdentity,
} from "../src/ui/scheduledCommands.js";
import { executeBuiltInQuickAction } from "../src/ui/speechGuard.js";
import { filterByListCut, orderAndAliasRooms } from "../src/ui/listCut.js";
import { onOpenURL } from "../src/core/appUrlCommand.js";
import { AutomationRuleStore, createAutomationRule } from "../src/core/automationEngine.js";
import { DualSourceCoordinator } from "../src/core/dualSourceProvider.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  buildIndexedCapabilityDevices,
  evaluateIntentsWriteGate,
  filterEnabledMiAccounts,
  miAccountScope,
  resolveMiAccountSelectionState,
  writeMiAccountSelectionMutation,
} from "../src/core/miAccountControl.js";
import { MiCloudError, MiotSpecResolver, parseMiotDeviceSpec, type HttpRequest, type HttpResponse, type HttpTransport, type MiSession } from "../src/core/miCloudClient.js";
import { scheduleDelayedReadBack } from "../src/core/optimisticLock.js";
import { getXiaomiBackoffUntilMs, recordXiaomiRateLimit } from "../src/core/pollingPolicy.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY } from "../src/core/scheduledCommands.js";
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

  it("preserves HA control for HA-exclusive and merged cards while rejecting Xiaomi-exclusive cards when sole Xiaomi account is disabled in dual-source", async () => {
    const miWrites: string[] = [];
    const haExecutes: Array<Record<string, unknown>> = [];
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") miWrites.push(path);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [{ id: "r1", name: "客厅", dids: ["101", "102"] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({
          list: [
            { did: "101", name: "客厅主灯", model: LIGHT_MODEL, isOnline: true },
            { did: "102", name: "米家独占灯", model: LIGHT_MODEL, isOnline: true },
          ],
        });
      }
      if (path === "miotspec/prop/get") {
        return okMi([
          { did: "101", siid: 2, piid: 1, code: 0, value: true },
          { did: "101", siid: 2, piid: 2, code: 0, value: 80 },
          { did: "102", siid: 2, piid: 1, code: 0, value: true },
          { did: "102", siid: 2, piid: 2, code: 0, value: 60 },
        ]);
      }
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [{ area_id: "a1", name: "客厅" }],
          devices: [
            { id: "ha-shared-101", area_id: "a1", name: "客厅主灯", model: LIGHT_MODEL, identifiers: [["xiaomi_home", "cn_101"]], connections: [] },
            { id: "ha-exclusive-1", area_id: "a1", name: "HA独占落地灯", model: LIGHT_MODEL, identifiers: [["zha", "zigbee-01"]], connections: [] },
          ],
          entities: [
            { entity_id: "light.shared_101", device_id: "ha-shared-101", area_id: null, disabled_by: null, hidden_by: null },
            { entity_id: "light.ha_only", device_id: "ha-exclusive-1", area_id: null, disabled_by: null, hidden_by: null },
          ],
          states: [
            { entity_id: "light.shared_101", state: "on", attributes: { friendly_name: "客厅主灯", brightness: 200 } },
            { entity_id: "light.ha_only", state: "on", attributes: { friendly_name: "HA独占落地灯", brightness: 180 } },
          ],
        } as unknown) as T;
      }
      if (cmd === "ha_execute") {
        haExecutes.push(args);
        return (null as unknown) as T;
      }
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    assert.equal(app.devices.length, 3, "expected HA-only + merged card + Mi-only");
    const haOnly = app.devices.find((d) => d.name === "HA独占落地灯")!;
    const mergedCard = app.devices.find((d) => d.name === "客厅主灯")!;
    const miOnlyBefore = app.devices.find((d) => d.name === "米家独占灯")!;
    assert.ok(haOnly && mergedCard && miOnlyBefore);

    // Disable the sole Xiaomi account in dual-source mode.
    const disabled = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(disabled.status, "applied");
    assert.equal(
      app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind,
      "disconnected",
      "disabled sole Xiaomi account must not report connected right after disable",
    );

    // Refresh again while sole Xiaomi account is disabled -> Xiaomi aggregate status must still not report connected!
    await refreshDevices(app, false);
    assert.equal(
      app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind,
      "disconnected",
      "dual-source empty Xiaomi snapshot when all accounts disabled must not report connected",
    );
    assert.equal(app.panelHealth().kind, "online");
    assert.doesNotMatch(app.panelHealth().label, /米家账号/);

    // 1. HA-exclusive device remains controllable via applyCommand and executeIntents.
    const haEntity = haOnly.kind.kind === "light" ? haOnly.kind.entityId : "";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: haEntity, isOn: false }), true);
    assert.equal(await app.executeIntents([{ targetId: haOnly.id, operation: { kind: "power", isOn: true } }], "开HA独占灯", "测试"), true);
    assert.equal(haExecutes.length, 2);

    // 2. Merged card (demoted to HA) remains controllable via applyCommand, executeIntents, and URL scheme!
    const mergedAfter = app.devices.find((d) => d.name === "客厅主灯")!;
    assert.ok(mergedAfter, "merged card stays on panel via HA");
    const mergedEntity = mergedAfter.kind.kind === "light" ? mergedAfter.kind.entityId : "";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: mergedEntity, isOn: false }), true);
    assert.equal(await app.executeIntents([{ targetId: mergedAfter.id, operation: { kind: "power", isOn: true } }], "开客厅主灯", "测试"), true);
    const urlToasts: string[] = [];
    await onOpenURL(`menumijia://power?device=${encodeURIComponent(mergedAfter.id)}&state=off`, {
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
    assert.equal(haExecutes.length, 5, `urlToasts=${JSON.stringify(urlToasts)}`);

    // 3. Xiaomi-exclusive device is rejected with account-disabled message and zero writes.
    const miEntity = miOnlyBefore.kind.kind === "light" ? miOnlyBefore.kind.entityId : "102.2.1";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: miEntity, isOn: false }), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.equal(await app.executeIntents([{ targetId: miOnlyBefore.id, operation: { kind: "power", isOn: true } }], "开米家独占灯", "测试"), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.deepEqual(miWrites, []);
    assert.equal(haExecutes.length, 5);
  });

  it("defers paused item revalidation on re-enable until a fresh Xiaomi snapshot succeeds", async () => {
    let failMiNetwork = false;
    const transport: HttpTransport = async (req) => {
      if (failMiNetwork) throw new Error("network down");
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

    const nowMs = Date.now();
    const idA = scheduledCommandIdentity(app.settings)!;
    const queueA = app.scheduledCommandStore.queue(idA);
    queueA.scheduledCommands = [
      { id: "timer_future", command: "调亮书房台灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "brightness", percent: 90 } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "rule_on", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(queueA.pausedScheduledCommands?.length, 1);
    assert.equal(ruleStore.load()[0]?.isEnabled, false);

    // 1. Re-enable while refresh returns early (isSyncingCloud = true) OR fails with network error: must NOT revalidate against empty device list!
    failMiNetwork = true;
    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 0, "failed refresh on re-enable must not move future timer to missed");
    assert.equal(queueA.pausedScheduledCommands?.length, 1, "timer remains safely paused until snapshot succeeds");
    assert.equal(ruleStore.load()[0]?.isEnabled, false, "rule stays paused until snapshot succeeds");

    // 2. Subsequent background/manual refresh succeeds -> revalidates and restores future timer, rule, and quickAction!
    failMiNetwork = false;
    await refreshDevices(app, false);
    assert.deepEqual(app.scheduledCommands.map((t) => t.id), ["timer_future"]);
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(ruleStore.load()[0]?.isEnabled, true);
    assert.equal(resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true }).pausedQuickActionIds.has("lightsOff"), false);
  });

  it("includes paused timers when cancelling all timers via 取消所有定时", async () => {
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

    const nowMs = Date.now();
    const queueA = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    queueA.scheduledCommands = [
      { id: "t_pause_1", command: "十分钟后关灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t_pause_2", command: "二十分钟后调暗", reply: "好", delaySeconds: 1200, fireTimestampMs: nowMs + 1_200_000, intents: [{ targetId: "101", operation: { kind: "brightness", percent: 20 } }] },
    ];
    app.scheduledCommandStore.persist();

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(queueA.pausedScheduledCommands?.length, 2);

    await app.handleNaturalCommand("取消所有定时");
    assert.match(app.replyBanner?.text ?? "", /已取消 2 项定时指令/);
    assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0);

    // Re-enabling must not resurrect cancelled timers!
    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 0);
  });

  it("prevents in-flight dual-source refresh from contaminating DualSourceCoordinator cache after account disable", async () => {
    let gateEnabled = false;
    let releaseMi!: () => void;
    const miGate = new Promise<void>((r) => { releaseMi = r; });
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (gateEnabled && (path === "v2/home/device_list_page" || path === "home/device_list")) {
        await miGate;
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "101", name: "米家书房灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 75 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), true);

    // Start an in-flight dual-source refresh, then disable ACC_A before fetchMi resolves!
    gateEnabled = true;
    const inFlight = refreshDevices(app, true);
    await new Promise((r) => setTimeout(r, 0));
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), false);

    releaseMi();
    await inFlight;

    // Trigger coordinator recompute via source pin change — stale Xiaomi device must NOT come back!
    setHostDeviceSourcePin(app, "light.ha_living", "homeAssistant");
    recomputeHostDualSource(app);
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), false, "stale in-flight refresh must not contaminate coordinator cache");
    assert.equal(app.dualSourceCoordinator?.getLastMerged()?.home.devices.some((d) => d.name === "米家书房灯") ?? false, false);
    assert.equal(app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind, "disconnected");
  });

  it("preserves full dual-source timer scopes across disable and re-enable so future timers re-arm waiting", async () => {
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") return okMi({ list: [{ did: "102", name: "米家独占台灯", model: LIGHT_MODEL, isOnline: true }] });
      if (path === "miotspec/prop/get") return okMi([{ did: "102", siid: 2, piid: 1, code: 0, value: true }, { did: "102", siid: 2, piid: 2, code: 0, value: 70 }]);
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    // 1) Enqueued timer in dual-source mode
    assert.equal(enqueueScheduledCommand(app, {
      id: "dual_enqueued", command: "五分钟后关米家独占台灯", reply: "好", delaySeconds: 300,
      fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "102", operation: { kind: "power", isOn: false } }],
    }), true);
    // 2) Pre-existing unstamped timer in active dual-source queue
    app.scheduledCommands.push({
      id: "dual_legacy", command: "十分钟后调亮米家独占台灯", reply: "好", delaySeconds: 600,
      fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "102", operation: { kind: "brightness", percent: 90 } }],
    });
    app.scheduledCommandStore.persist();

    const disabled = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(disabled.status, "applied");
    assert.equal(app.scheduledCommands.length, 0);

    const reenabled = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 10_000 });
    assert.equal(reenabled.status, "applied");
    assert.deepEqual(
      new Set(app.scheduledCommands.map((t) => t.id)),
      new Set(["dual_enqueued", "dual_legacy"]),
      "future dual-source timers must re-arm waiting instead of moving to missed",
    );
    assert.equal(app.missedScheduledCommands.length, 0);
  });

  it("rolls back atomically on storage write failure and displays clear trilingual banners when disable is blocked", async () => {
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") return okMi({ list: [{ did: "101", name: "书房台灯", model: LIGHT_MODEL, isOnline: true }] });
      if (path === "miotspec/prop/get") return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }]);
      return okMi({});
    };

    const secure = makeSecure();
    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    const devAId = app.devices.find((d) => d.name === "主号台灯")?.id ?? `${ACC_A}/101`;
    const queueA = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    queueA.scheduledCommands = [
      { id: "t_atomic", command: "关书房台灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: devAId, operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "rule_atomic", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: [devAId], isOn: false } }),
    ]);

    // 1) Simulate capability selection write failure -> timers & rules must NOT stay paused!
    const origSetItem = localStorage.setItem.bind(localStorage);
    let failCapabilityWrite = true;
    Object.defineProperty(localStorage, "setItem", {
      configurable: true,
      writable: true,
      value: (key: string, val: string): void => {
        if (failCapabilityWrite && key === MI_ACCOUNT_CAPABILITY_STORAGE_KEY) {
          throw new Error("QuotaExceededError");
        }
        origSetItem(key, val);
      },
    });
    try {
      const outcome = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
      assert.equal(outcome.status, "blocked");
      assert.equal(app.scheduledCommands.length, 1, "timer must remain active when selection write fails");
      assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0, "paused timers must roll back on selection write failure");
      assert.equal(ruleStore.load()[0]?.isEnabled, true, "automation rule must remain enabled when selection write fails");
      assert.equal(ruleStore.load()[0]?.pausedByCapabilities, undefined);
      assert.equal(app.replyBanner?.isError, true);
    } finally {
      failCapabilityWrite = false;
      Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: origSetItem });
    }

    // 2) Trigger unresolvedReferenceOwnership (timer targets unknown device while ACC_B stays enabled) -> blocked banner in UI & replyBanner!
    queueA.scheduledCommands = [
      { id: "t_unknown_owner", command: "关未知设备", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "unknown-did-999", operation: { kind: "power", isOn: false } }], sourceScopes: [ACC_A, ACC_B] },
    ];
    app.scheduledCommandStore.persist();
    app.openSettingsSheet("connection");
    const blockedZh = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(blockedZh.status, "blocked");
    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /刷新|同步/);
    const errEl = document.querySelector<HTMLElement>(`[data-mi-account-disable-error="${ACC_A}"]`);
    assert.ok(errEl, "expected inline blocked error banner inside account card");

    setLanguage("zh-Hant");
    await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.match(app.replyBanner?.text ?? "", /重新整理|同步/);

    setLanguage("en");
    await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.match(app.replyBanner?.text ?? "", /refresh/i);
    setLanguage("zh-Hans");
  });

  it("checks preview generation before confirming disable and re-previews when affected items change", async () => {
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

    const nowMs = Date.now();
    app.scheduledCommands = [
      { id: "t_gen_1", command: "关灯一", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();

    app.openSettingsSheet("connection");
    const connPanel = document.querySelector<HTMLElement>('[data-settings-panel="connection"]')!;
    const toggle = connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)!;
    toggle.checked = false;
    toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));

    assert.ok(connPanel.querySelector(`[data-mi-account-pause-preview="${ACC_A}"]`));

    // Mutate timers after preview was shown, before user clicks confirm!
    app.scheduledCommands.push({
      id: "t_gen_2", command: "新加关灯二", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }],
    });
    app.scheduledCommandStore.persist();

    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-confirm-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));

    // Must NOT have disabled or paused t_gen_2 without showing updated preview!
    assert.equal(app.scheduledCommands.length, 2, "unpreviewed timer must not be paused on stale generation");
    const updatedPreview = connPanel.querySelector<HTMLElement>(`[data-mi-account-pause-preview="${ACC_A}"]`);
    assert.ok(updatedPreview, "fresh preview must remain open after generation mismatch");
    assert.match(updatedPreview.textContent ?? "", /新加关灯二/);

    // Second confirm on matching generation succeeds and pauses both timers!
    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-confirm-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)?.checked, false);
  });

  it("renders human-readable preview names with 等 suffix and gives trilingual feedback when clicking paused quick actions", async () => {
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

    const nowMs = Date.now();
    app.scheduledCommands = [
      { id: "t1", command: "定时一", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t2", command: "定时二", reply: "好", delaySeconds: 120, fireTimestampMs: nowMs + 120_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "rule_1712345678", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    // 5 affected items total: t1, t2, rule_1712345678, lightsOff, softNightLight (> 4 -> shows 等, and rule_1712345678 + lightsOff are in first 4!)
    app.openSettingsSheet("connection");
    const previewRes = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(previewRes.status, "requiresPauseConfirmation");
    if (previewRes.status === "requiresPauseConfirmation") {
      const names = previewRes.verdict.itemsToPause.map((i) => i.name);
      assert.equal(names.some((n) => n.includes("rule_17")), false, `internal rule id leaked: ${names.join(",")}`);
      assert.equal(names.some((n) => n === "lightsOff" || n === "softNightLight"), false, `internal quickAction id leaked: ${names.join(",")}`);
      assert.equal(names.some((n) => n.includes("全屋关灯")), true, `expected localized quickAction title in ${names.join(",")}`);
      assert.equal(names.some((n) => n.includes("书房台灯")), true, `expected human-readable rule summary in ${names.join(",")}`);
    }
    const previewBox = document.querySelector<HTMLElement>(`[data-mi-account-pause-preview="${ACC_A}"]`)!;
    assert.doesNotMatch(previewBox.textContent ?? "", /rule_1712345678|lightsOff/);
    assert.match(previewBox.textContent ?? "", /等/);

    // Confirm pause, then click paused quickAction -> clear feedback in zh-Hans, zh-Hant, en!
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    const readBannerText = (): string => app.replyBanner?.text ?? "";
    app.replyBanner = null;
    await executeBuiltInQuickAction(app, "lightsOff");
    assert.match(readBannerText(), /全屋关灯.*连接/);

    setLanguage("zh-Hant");
    app.replyBanner = null;
    await executeBuiltInQuickAction(app, "lightsOff");
    assert.match(readBannerText(), /全屋關燈.*連線/);

    setLanguage("en");
    app.replyBanner = null;
    await executeBuiltInQuickAction(app, "lightsOff");
    assert.match(readBannerText(), /All Lights Off.*connection/i);
    setLanguage("zh-Hans");
  });

  it("keeps Home Assistant and Demo devices, facets, and readings intact when disabling a Xiaomi account with dual-source off (4622786203)", async () => {
    const secure = makeSecure();
    const app = mountApp(async () => okMi({}), secure);
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    app.settings.miSession = SESS_A;
    setHostDualSourceEnabled(app, false, { persist: true });
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);

    let haExecutes = 0;
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [{ area_id: "a1", name: "客厅" }],
          devices: [
            { id: "ha-dev-light", area_id: "a1", name: "HA吸顶灯" },
            { id: "ha-dev-sensor", area_id: "a1", name: "HA温湿度计" },
          ],
          entities: [
            { entity_id: "light.ha_ceiling", device_id: "ha-dev-light" },
            { entity_id: "switch.ha_ceiling_night", device_id: "ha-dev-light" },
            { entity_id: "sensor.ha_temp", device_id: "ha-dev-sensor" },
          ],
          states: [
            { entity_id: "light.ha_ceiling", state: "on", attributes: { friendly_name: "HA吸顶灯", brightness: 200 } },
            { entity_id: "switch.ha_ceiling_night", state: "off", attributes: { friendly_name: "夜灯开关" } },
            { entity_id: "sensor.ha_temp", state: "24.5", attributes: { friendly_name: "HA温湿度计", device_class: "temperature", unit_of_measurement: "°C" } },
          ],
        } as unknown) as T;
      }
      if (cmd === "ha_execute") {
        haExecutes += 1;
      }
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    const haLight = app.devices.find((d) => d.name === "HA吸顶灯");
    assert.ok(haLight, "expected HA light card");
    const haLightId = haLight.id;
    const readingsBefore = app.environmentReadings.length;
    assert.ok(readingsBefore > 0, "expected HA environment reading");
    app.deviceFacets = {
      ...app.deviceFacets,
      [haLightId]: [{
        id: "night", kind: "toggle", name: "night", title: "夜灯", serviceName: "switch",
        unit: null, scale: null, value: false, options: [], range: null,
        isWritable: true, writesByDefault: true, isHighValue: true,
        target: { kind: "property", entityId: "switch.ha_ceiling_night", piid: 1 },
      }],
    };

    const outcome = await setMiAccountEnabledOnHost(app, ACC_A, false);
    assert.equal(outcome.status, "applied");
    assert.equal(app.devices.some((d) => d.id === haLightId), true, "HA card must remain on panel");
    assert.equal(app.environmentReadings.length, readingsBefore, "HA environment readings must remain intact");
    assert.equal(app.deviceFacets[haLightId]?.length, 1, "HA device facets must remain intact");
    const stateAfter = resolveMiAccountSelectionState({
      storage: localStorage, accounts: [makeMiAccount(SESS_A)],
      haBaseURL: app.settings.haBaseURL, haToken: app.settings.haToken,
      connectionMode: "homeAssistant", dualSourceEnabled: false, hasExistingPreferences: true,
    });
    assert.equal(stateAfter.knownDisabledDevices.some((d) => d.id === haLightId), false, "HA card must not enter knownDisabledDevices");
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "light.ha_ceiling", isOn: false }), true);
    assert.equal(haExecutes, 1);

    // Demo mode must also keep demo devices intact and out of knownDisabledDevices when disabling a stored Xiaomi account.
    await store.upsertAccount(SESS_B);
    app.settings.connectionMode = "demo";
    app.devices = [
      {
        id: "demo_desk_lamp",
        name: "演示台灯",
        roomId: "study",
        roomName: "书房",
        model: "demo.light",
        isOnline: true,
        kind: { kind: "light", entityId: "light.demo_desk", isOn: true, brightnessPercent: 80, colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, availableEffects: [], currentEffect: null },
      },
    ];
    const demoOutcome = await setMiAccountEnabledOnHost(app, ACC_B, false);
    assert.equal(demoOutcome.status, "applied");
    assert.equal(app.devices.some((d) => d.id === "demo_desk_lamp"), true, "Demo card must remain on panel");
    const stateAfterDemo = resolveMiAccountSelectionState({
      storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)],
      connectionMode: "demo", dualSourceEnabled: false, hasExistingPreferences: true,
    });
    assert.equal(stateAfterDemo.knownDisabledDevices.some((d) => d.id === "demo_desk_lamp"), false, "Demo card must not enter knownDisabledDevices");
  });

  it("queues revalidation when QR login re-enables a disabled account and unsticks paused items on sign-out (4622786217)", async () => {
    let failRefresh = false;
    let executedCommands = 0;
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (failRefresh) throw new Error("temporary network failure");
      if (path === "miotspec/prop/set") {
        executedCommands += 1;
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主号台灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "202", name: "副号落地灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const did = user === "10001" ? "101" : "202";
        return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    app.scheduledCommands = [
      { id: "qr_expired", command: "一分钟后关灯", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "qr_future", command: "十分钟后关灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_qr_auto", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "r_qr_manual_off", isEnabled: false, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_auto")?.isEnabled, false);

    // Re-login SESS_A via addOrUpdateMiAccountOnHost while first refresh fails -> stays pending revalidation!
    failRefresh = true;
    await addOrUpdateMiAccountOnHost(app, { ...SESS_A, serviceToken: "tok-a-rescanned" });
    const midState = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
    assert.equal(midState.disabledAccountIds.has(ACC_A), false);
    assert.equal(midState.pendingRevalidationAccountIds.has(ACC_A), true, "QR login of disabled account must retain pendingRevalidationAccountIds until fresh snapshot succeeds");
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_auto")?.isEnabled, false, "must not resume before fresh snapshot succeeds");

    // Subsequent refresh succeeds at nowMs + 120s -> future timer re-arms, expired timer moves to missed without auto-firing, auto rule resumes, manual-off rule stays off, quickAction restores!
    failRefresh = false;
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await refreshDevices(app, false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    processScheduledCommands(app, nowMs + 120_000);
    assert.equal(executedCommands, 0, "expired timer must not auto-fire after QR re-login");
    assert.deepEqual(app.scheduledCommands.map((t) => t.id), ["qr_future"]);
    assert.deepEqual(app.missedScheduledCommands.map((t) => t.id), ["qr_expired"]);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_auto")?.isEnabled, true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_manual_off")?.isEnabled, false, "manually disabled rule must stay off");
    const afterLoginState = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
    assert.equal(afterLoginState.pendingRevalidationAccountIds.has(ACC_A), false);
    assert.equal(afterLoginState.pausedQuickActionIds.has("lightsOff"), false);

    // Part B: Sign-out / removal of a disabled account must NOT leave paused timers, rules, or quickActions permanently stuck!
    app.scheduledCommands = [];
    app.missedScheduledCommands = [];
    app.scheduledCommandStore.persist();
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    const devB = app.devices.find((d) => d.name === "副号落地灯");
    assert.ok(devB, "expected secondary account device");

    app.scheduledCommands = [
      { id: "signout_b_timer", command: "五分钟后关副号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 500_000, intents: [{ targetId: devB.id, operation: { kind: "power", isOn: false } }], sourceScopes: [ACC_A, ACC_B] },
    ];
    app.scheduledCommandStore.persist();
    ruleStore.save([
      createAutomationRule({ id: "r_qa_signout", isEnabled: true, trigger: "screenLocked", action: { kind: "quickAction", quickAction: "lightsOff" } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true, nowMs });
    // Remove ACC_B via Settings UI while ACC_A stays enabled -> signout_b_timer must move out of pausedScheduledCommands into missedScheduledCommands (not stuck forever!), and r_qa_signout stays active on ACC_A!
    app.openSettingsSheet("connection");
    const removeBBtn = document.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${ACC_B}"]`);
    assert.ok(removeBBtn, "expected sign-out button for secondary account B");
    removeBBtn.click();
    for (
      let i = 0;
      i < 40 && (store.getAccounts().some((a) => a.id === ACC_B) || (app.connDiagSession?.signingOutAccountIds.size ?? 0) > 0);
      i += 1
    ) {
      await new Promise((r) => setTimeout(r, 0));
    }
    await new Promise((r) => setTimeout(r, 0));
    const activeQueueAfterRemoveB = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    assert.equal(activeQueueAfterRemoveB.pausedScheduledCommands?.length ?? 0, 0, "paused timer of removed account must not stay stuck in pausedScheduledCommands");
    assert.equal(app.missedScheduledCommands.some((t) => t.id === "signout_b_timer"), true, "removed account's paused timer moves to missed without firing");

    // Now disable remaining ACC_A (pausing lightsOff + r_qa_signout), then sign out Xiaomi completely -> pausedQuickActionIds & quickAction rule must NOT stay stuck!
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true }).pausedQuickActionIds.has("lightsOff"), true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qa_signout")?.isEnabled, false);

    signOutXiaomiAccount(app);
    await new Promise((r) => setTimeout(r, 0));
    app.settings.connectionMode = "demo";
    const demoState = resolveMiAccountSelectionState({ storage: localStorage, accounts: [], connectionMode: "demo", hasExistingPreferences: true });
    assert.equal(demoState.pausedQuickActionIds.size, 0, "signing out all Xiaomi accounts must clear stuck pausedQuickActionIds");
    assert.equal(ruleStore.load().find((r) => r.id === "r_qa_signout")?.isEnabled, true, "signing out all Xiaomi accounts must unstick paused quickAction rule");
  });

  it("tags scenes according to connectionMode and dualSourceEnabled instead of unconditionally marking them Home Assistant (4622827966)", async () => {
    const app = mountApp(async () => okMi({}));
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.devices = [];
    // Leftover HA credentials while dual-source is OFF!
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "leftover-ha-tok";
    setHostDualSourceEnabled(app, false, { persist: true });
    app.scenes = [{ id: "mi_scene_night", name: "米家晚安", entityId: "101.2.a1" }];

    const ctxXiaomiOnly = buildHostCapabilityContext(app, [makeMiAccount(SESS_A)]);
    const indexedXiaomiOnly = buildIndexedCapabilityDevices(ctxXiaomiOnly);
    assert.equal(indexedXiaomiOnly.sceneRefs[0]?.connection, "xiaomi-cloud", "Xiaomi-only mode must not tag scenes as home-assistant");
    assert.equal(indexedXiaomiOnly.sceneRefs[0]?.sourceScope, ACC_A);
    assert.equal(
      evaluateIntentsWriteGate({
        intents: [{ targetId: "mi_scene_night", operation: { kind: "activateScene" } }],
        context: ctxXiaomiOnly,
      }),
      null,
      "scene execution in Xiaomi-only mode with leftover HA settings must not be rejected as disabled HA",
    );

    // Dual-source ON with both an HA scene and a Xiaomi scene: disabling ACC_A pauses Xiaomi scene rule & blocks Xiaomi scene write before high-risk, while HA scene stays active!
    setHostDualSourceEnabled(app, true, { persist: true });
    app.scenes = [
      { id: "scene.ha_movie", name: "HA观影", entityId: "scene.ha_movie" },
      { id: `${ACC_A}/sc_mi_leave`, name: "米家离家", entityId: "101.2.a2" },
    ];
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_ha_scene", isEnabled: true, trigger: "screenLocked", action: { kind: "scene", sceneId: "scene.ha_movie" } }),
      createAutomationRule({ id: "r_mi_scene", isEnabled: true, trigger: "screenLocked", action: { kind: "scene", sceneId: `${ACC_A}/sc_mi_leave` } }),
    ]);

    const previewDual = await setMiAccountEnabledOnHost(app, ACC_A, false);
    assert.equal(previewDual.status, "requiresPauseConfirmation", "Xiaomi scene automation in dual-source must require pause confirmation");
    const appliedDual = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(appliedDual.status, "applied");
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_scene")?.isEnabled, false, "Xiaomi scene rule must pause when Xiaomi account is disabled");
    assert.equal(ruleStore.load().find((r) => r.id === "r_ha_scene")?.isEnabled, true, "HA scene rule must stay enabled in dual-source");

    // Keep Xiaomi scene reference in host.scenes to verify write gate rejects disabled Xiaomi scene!
    app.scenes = [
      { id: "scene.ha_movie", name: "HA观影", entityId: "scene.ha_movie" },
      { id: `${ACC_A}/sc_mi_leave`, name: "米家离家", entityId: "101.2.a2" },
    ];
    const ctxAfterDisable = buildHostCapabilityContext(app, [makeMiAccount(SESS_A)]);
    assert.equal(
      evaluateIntentsWriteGate({
        intents: [{ targetId: "scene.ha_movie", operation: { kind: "activateScene" } }],
        context: ctxAfterDisable,
      }),
      null,
    );
    assert.match(
      evaluateIntentsWriteGate({
        intents: [{ targetId: `${ACC_A}/sc_mi_leave`, operation: { kind: "activateScene" } }],
        context: ctxAfterDisable,
      }) ?? "",
      /停用/,
    );
  });

  it("keeps pendingRevalidationAccountIds until timer, rule, and selection persistence all succeed (4622827975)", async () => {
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

    const nowMs = Date.now();
    app.scheduledCommands = [
      { id: "t_retry", command: "十分钟后关灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_retry", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(ruleStore.load()[0]?.isEnabled, false);

    const origSetItem = localStorage.setItem.bind(localStorage);
    let blockedKey: string | null = SCHEDULED_COMMANDS_STORAGE_KEY;
    Object.defineProperty(localStorage, "setItem", {
      configurable: true,
      writable: true,
      value: (key: string, val: string): void => {
        if (blockedKey !== null && key === blockedKey) {
          throw new Error("QuotaExceededError");
        }
        origSetItem(key, val);
      },
    });
    try {
      // 1) Re-enable while timer store persist fails -> token MUST remain pending!
      await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
      const stateAfterTimerFail = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
      assert.equal(stateAfterTimerFail.pendingRevalidationAccountIds.has(ACC_A), true, "pendingRevalidationAccountIds must survive failed timer persist");

      // 2) Next refresh: timer persist succeeds, rule store save fails -> token MUST still remain pending!
      blockedKey = AutomationRuleStore.storageKey;
      await refreshDevices(app, false);
      const stateAfterRuleFail = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
      assert.equal(stateAfterRuleFail.pendingRevalidationAccountIds.has(ACC_A), true, "pendingRevalidationAccountIds must survive failed rule save");
      assert.equal(ruleStore.load()[0]?.isEnabled, false);

      // 3) Next refresh: all persistence succeeds -> timer armed, rule resumed, quickAction restored, token cleared!
      blockedKey = null;
      await refreshDevices(app, false);
      const stateAfterSuccess = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
      assert.equal(stateAfterSuccess.pendingRevalidationAccountIds.has(ACC_A), false);
      assert.equal(stateAfterSuccess.pausedQuickActionIds.has("lightsOff"), false);
      assert.equal(app.scheduledCommands.some((t) => t.id === "t_retry"), true);
      assert.equal(ruleStore.load()[0]?.isEnabled, true);
    } finally {
      Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: origSetItem });
    }
  });

  it("drops stale multi-account refresh on re-enable and supersedes in-flight sync so re-enabled devices and revalidation land immediately (4622827982)", async () => {
    let gateAccA = false;
    let releaseAccA!: () => void;
    const makeGate = () => new Promise<void>((r) => { releaseAccA = r; });
    let currentGate = makeGate();
    const secure = makeSecure();

    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (gateAccA && user === "10001" && (path === "v2/home/device_list_page" || path === "home/device_list")) {
        await currentGate;
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主号台灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "202", name: "副号台灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const did = user === "10001" ? "101" : "202";
        return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 75 }]);
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
    const devBInitial = app.devices.find((d) => d.name === "副号台灯");
    assert.ok(devBInitial, "expected secondary account device");
    const devBId = devBInitial.id;

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_b_inflight", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: [devBId], isOn: false } }),
    ]);
    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true });
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), false);
    assert.equal(ruleStore.load()[0]?.isEnabled, false);

    // 1) Direct selection mutation re-enabling ACC_B during an in-flight multi-account refresh of [ACC_A] must NOT commit stale [ACC_A]-only snapshot over newer panel state!
    currentGate = makeGate();
    gateAccA = true;
    const stalePoll = refreshDevices(app, true);
    await new Promise((r) => setTimeout(r, 0));
    app.devices = [
      ...app.devices,
      { id: devBId, accountId: ACC_B, name: "副号台灯", roomId: "r2", roomName: "卧室", model: LIGHT_MODEL, isOnline: true, kind: { kind: "light", entityId: "202.2.1", isOn: true, brightnessPercent: 75, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, availableEffects: [], currentEffect: null } },
    ];
    writeMiAccountSelectionMutation({
      mutate: (prev) => ({
        ...prev,
        disabledAccountIds: prev.disabledAccountIds.filter((id) => id !== ACC_B),
        pendingRevalidationAccountIds: [...new Set([...prev.pendingRevalidationAccountIds, miAccountScope(ACC_B)])],
      }),
    });
    gateAccA = false;
    releaseAccA();
    await stalePoll;
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), true, "in-flight refresh started before re-enable must not overwrite panel without restored account");

    // 2) Now disable ACC_B again, start another in-flight refresh of [ACC_A], and call setMiAccountEnabledOnHost(app, ACC_B, true) while [ACC_A] is still in flight!
    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true });
    currentGate = makeGate();
    gateAccA = true;
    const inFlightBeforeToggle = refreshDevices(app, true);
    await new Promise((r) => setTimeout(r, 0));
    gateAccA = false;
    const reenablePromise = setMiAccountEnabledOnHost(app, ACC_B, true);
    releaseAccA();
    await Promise.all([inFlightBeforeToggle, reenablePromise]);
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), true, "re-enabling during in-flight refresh must immediately sync restored account");
    assert.equal(ruleStore.load()[0]?.isEnabled, true, "re-enabling during in-flight refresh must complete pending revalidation");
  });

  it("preserves remaining disconnected Xiaomi accounts in DualSourceCoordinator.removeXiaomiAccount and distinguishes disconnected vs turned off in all 3 languages (4622827993)", async () => {
    let failAccBMode: "none" | "http" | "expired" = "none";
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (user === "20002" && failAccBMode === "http") {
        throw new MiCloudError("http", "米家网络暂时不可用", 503);
      }
      if (user === "20002" && failAccBMode === "expired") {
        throw new MiCloudError("sessionExpired", "米家登录已过期", 401);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: `Home-${user}`, roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主号台灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "202", name: "副号独占台灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const did = user === "10001" ? "101" : "202";
        return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);

    // 1) Initial dual-source refresh: both ACC_A and ACC_B connected.
    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true);

    // 2) Second refresh: ACC_A stays connected while ACC_B transiently disconnects (cached device preserved).
    failAccBMode = "http";
    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true);

    // 3) Disable ACC_A while ACC_B is still enabled (though disconnected): ACC_B's cached device MUST stay on panel and status must report real disconnect, NOT turned off!
    await setMiAccountEnabledOnHost(app, ACC_A, false);
    assert.equal(app.devices.some((d) => d.name === "主号台灯"), false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true, "enabled disconnected account's cached devices must not be wiped");
    const miStatusAfterDisableA = app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud;
    assert.equal(miStatusAfterDisableA?.kind, "disconnected");
    if (miStatusAfterDisableA?.kind === "disconnected") {
      assert.match(miStatusAfterDisableA.reason, /网络暂时不可用/);
      assert.doesNotMatch(miStatusAfterDisableA.reason, /停用|turned off/i, "must report real disconnect reason instead of turned off");
    }

    // 3b) Also verify when remaining enabled ACC_B has 0 cached devices (sessionExpired): disabling ACC_A still reports ACC_B's expired reason instead of turned off.
    failAccBMode = "expired";
    await setMiAccountEnabledOnHost(app, ACC_A, true);
    assert.equal(app.devices.some((d) => d.name === "主号台灯"), true);
    await setMiAccountEnabledOnHost(app, ACC_A, false);
    const miStatusExpiredB = app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud;
    assert.equal(miStatusExpiredB?.kind, "disconnected");
    if (miStatusExpiredB?.kind === "disconnected") {
      assert.match(miStatusExpiredB.reason, /过期/);
      assert.doesNotMatch(miStatusExpiredB.reason, /停用|turned off/i);
    }

    // 4) Trilingual distinction between disconnected vs turned off on DualSourceCoordinator:
    for (const [lang, expectedDisc, expectedOff] of [
      ["zh-Hans", /断开|过期/, /米家已停用/],
      ["zh-Hant", /中斷|過期/, /米家已停用/],
      ["en", /disconnected|expired/i, /Xiaomi Home is turned off/],
    ] as const) {
      const c1 = new DualSourceCoordinator(null);
      c1.removeXiaomiAccount(ACC_A, lang, { remainingEnabledCount: 0, reason: "signedOut" });
      const s1 = c1.getSourceStatuses().xiaomiCloud;
      assert.equal(s1.kind, "disconnected");
      if (s1.kind === "disconnected") assert.match(s1.reason, expectedDisc);

      const c2 = new DualSourceCoordinator(null);
      c2.removeXiaomiAccount(ACC_A, lang, { remainingEnabledCount: 0, reason: "disabled" });
      const s2 = c2.getSourceStatuses().xiaomiCloud;
      assert.equal(s2.kind, "disconnected");
      if (s2.kind === "disconnected") assert.match(s2.reason, expectedOff);
    }
  });

  it("keeps shared Xiaomi device references active when another enabled Xiaomi account still owns the device (4623357855)", async () => {
    const executedByUser: string[] = [];
    let light101On = true;
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (path === "miotspec/prop/set") {
        executedByUser.push(user);
        light101On = false;
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({
          homelist: [{ id: user === "10001" ? "9101" : "9202", name: `Home-${user}`, roomlist: [{ id: `r-${user}`, name: "客厅", dids: user === "10001" ? ["101", "102"] : ["101"] }] }],
        });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({
              list: [
                { did: "101", name: "共享吸顶灯", model: LIGHT_MODEL, isOnline: true },
                { did: "102", name: "主号独占插座", model: HEATER_PLUG_MODEL, isOnline: true },
              ],
            })
          : okMi({
              list: [{ did: "101", name: "共享吸顶灯", model: LIGHT_MODEL, isOnline: true }],
            });
      }
      if (path === "miotspec/prop/get") {
        return okMi([
          { did: "101", siid: 2, piid: 1, code: 0, value: light101On },
          { did: "101", siid: 2, piid: 2, code: 0, value: 80 },
          { did: "102", siid: 2, piid: 1, code: 0, value: true },
        ]);
      }
      return okMi({});
    };

    // Part A: Multi-account Xiaomi single-source mode
    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    assert.deepEqual(app.multiAccountState?.merged.deviceOwners["101"], [ACC_A, ACC_B]);
    const nowMs = Date.now();
    app.scheduledCommands = [
      { id: "t_shared_101", command: "五分钟后关共享灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_shared_101", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    // Disabling ACC_A while ACC_B still owns "101" must NOT require pause confirmation or pause shared references!
    const disableA = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(disableA.status, "applied", "shared device still reachable via ACC_B must not require pause confirmation");
    assert.equal(app.scheduledCommands.some((t) => t.id === "t_shared_101"), true, "timer on shared device must remain active");
    assert.equal(ruleStore.load().find((r) => r.id === "r_shared_101")?.isEnabled, true, "automation on shared device must remain enabled");
    const stateAfterA = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)], hasExistingPreferences: true });
    assert.equal(stateAfterA.pausedQuickActionIds.has("lightsOff"), false, "lightsOff must remain active when shared light is reachable via ACC_B");
    assert.equal(stateAfterA.knownDisabledDevices.some((d) => d.id === "101"), false, "shared device must not enter knownDisabledDevices");
    assert.equal(app.devices.some((d) => d.id === "101"), true, "shared device must stay on panel");
    assert.equal(app.devices.some((d) => d.id === "102"), false, "ACC_A-only device must be removed");

    // Direct control on shared "101" immediately routes via ACC_B (20002) even before next poll!
    const sharedLightEntityId = (app.devices.find((d) => d.id === "101")!.kind as { entityId: string }).entityId;
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: sharedLightEntityId, isOn: false }), true);
    assert.deepEqual(executedByUser, ["20002"]);

    // Disabling ACC_B (now the LAST enabled owner of "101") MUST require pause confirmation and pause them!
    const previewB = await setMiAccountEnabledOnHost(app, ACC_B, false, { nowMs });
    assert.equal(previewB.status, "requiresPauseConfirmation", "disabling the last enabled owner must require pause confirmation");
    const confirmB = await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true, nowMs });
    assert.equal(confirmB.status, "applied");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "r_shared_101")?.isEnabled, false);

    // Part B: Dual-source mode (HA has unrelated plug, shared light "101" only in ACC_A + ACC_B)
    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    await setMiAccountEnabledOnHost(app, ACC_B, true, { nowMs: nowMs + 5_000 });
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-plug-1", name: "HA插座" }],
          entities: [{ entity_id: "switch.ha_plug", device_id: "ha-plug-1" }],
          states: [{ entity_id: "switch.ha_plug", state: "on", attributes: { friendly_name: "HA插座" } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    await refreshDevices(app, false);
    const dualDisableA = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs: nowMs + 10_000 });
    assert.equal(dualDisableA.status, "applied", "dual-source disable of ACC_A must keep shared Xiaomi light active via ACC_B");
    assert.equal(app.devices.some((d) => d.id === "101"), true, "shared Xiaomi light must remain in dual-source merged snapshot via ACC_B");
    assert.equal(app.scheduledCommands.some((t) => t.id === "t_shared_101"), true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_shared_101")?.isEnabled, true);
  });

  it("preserves multi-account room and home ID namespacing when refreshing after disabling one Xiaomi account (4623357863)", async () => {
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return user === "10001"
          ? okMi({ homelist: [{ id: "9101", name: "主家", roomlist: [{ id: "r-main", name: "主卧", dids: ["101"] }] }] })
          : okMi({ homelist: [{ id: "9202", name: "副家", roomlist: [{ id: "r-sec", name: "次卧", dids: ["202"] }] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主卧吸顶灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "202", name: "次卧台灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const did = user === "10001" ? "101" : "202";
        return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 75 }]);
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

    const scopedRoomB = `${ACC_B}/room_r-sec`;
    const scopedHomeB = `${ACC_B}/9202`;
    assert.equal(app.devices.find((d) => d.id === "202")?.roomId, scopedRoomB);
    assert.equal(app.homes.some((h) => h.id === scopedHomeB), true);

    app.settings.layout.roomAliases = { [scopedRoomB]: "温馨次卧" };
    app.settings.layout.roomOrder = [scopedRoomB, `${ACC_A}/room_r-main`];
    app.selectRoom(scopedRoomB, "温馨次卧");

    await setMiAccountEnabledOnHost(app, ACC_A, false);
    // Subsequent refresh in multi-account Xiaomi mode with only 1 enabled account (out of 2 signed-in):
    await refreshDevices(app, false);
    const devBAfter = app.devices.find((d) => d.id === "202");
    assert.equal(devBAfter?.roomId, scopedRoomB, "single remaining enabled account must keep account-scoped roomId");
    assert.equal(app.homes.some((h) => h.id === scopedHomeB), true, "single remaining enabled account must keep account-scoped homeId");
    const cutDevices = filterByListCut(app.devices, app.listCut, false, { layout: app.layout });
    assert.equal(cutDevices.length, 1, "listCut room filter must still match remaining account devices");
    assert.equal(cutDevices[0]?.roomName, "温馨次卧", "room alias keyed by scoped roomId must remain intact");
    const orderedRooms = orderAndAliasRooms([{ id: devBAfter!.roomId, name: devBAfter!.roomName }], app.layout);
    assert.equal(orderedRooms[0]?.name, "温馨次卧");

    // Subsequent refresh in Dual-Source mode with 1 enabled Xiaomi account (out of 2 signed-in):
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [{ area_id: "ha_living", name: "HA客厅" }],
          devices: [{ id: "ha-dev-1", area_id: "ha_living", name: "HA吸顶灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA吸顶灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    await refreshDevices(app, false);
    const devBDual = app.devices.find((d) => d.id === "202");
    assert.equal(devBDual?.roomId, scopedRoomB, "dual-source refresh must also preserve account-scoped roomId");
    assert.equal(app.homes.some((h) => h.id === scopedHomeB), true, "dual-source refresh must also preserve account-scoped homeId");
    const dualCutDevices = filterByListCut(app.devices, app.listCut, false, { layout: app.layout });
    assert.equal(dualCutDevices.length, 1);
    assert.equal(dualCutDevices[0]?.roomName, "温馨次卧");
  });

  it("does not prematurely expire Xiaomi timers or unpause lightsOff on Home Assistant refresh while Xiaomi revalidation is pending (4623387411)", async () => {
    let executedMiCommands = 0;
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") {
        executedMiCommands += 1;
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "101", name: "米家书房灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await refreshDevices(app, false);
    app.scenes = [{ id: `${ACC_A}/sc_night`, accountId: ACC_A, sourceBackend: "xiaomiCloud", name: "米家晚安", entityId: "101.2.a1" }];
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    const miIdentity = scheduledCommandIdentity(app.settings);
    const miQueue = app.scheduledCommandStore.queue(miIdentity);
    miQueue.scheduledCommands = [
      { id: "t_mi_valid_future", command: "十分钟后关书房灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t_mi_valid_scene", command: "十分钟后执行晚安场景", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: `${ACC_A}/sc_night`, operation: { kind: "activateScene" } }] },
      { id: "t_mi_expired", command: "一分钟后关书房灯", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_mi_pending_dev", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "r_mi_pending_qa", isEnabled: true, trigger: "screenLocked", action: { kind: "quickAction", quickAction: "lightsOff" } }),
    ]);

    const disabled = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(disabled.status, "applied");
    assert.equal(miQueue.pausedScheduledCommands?.length, 3);
    assert.equal(resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true }).pausedQuickActionIds.has("lightsOff"), true);

    // Switch to single-source Home Assistant mode (dualSourceEnabled = false) where HA has its own light!
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, false, { persist: true });
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });

    // Also place a dual-source-origin paused Xiaomi scene timer in the active HA queue to verify active-queue protection:
    const haIdentity = scheduledCommandIdentity(app.settings);
    const haQueue = app.scheduledCommandStore.queue(haIdentity);
    haQueue.pausedScheduledCommands = [
      {
        command: { id: "t_dual_mi_scene", command: "五分钟后米家晚安", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: `${ACC_A}/sc_night`, operation: { kind: "activateScene" } }], sourceScopes: [`ha:https://ha.example.test:8123`, ACC_A] },
        originalPartition: "waiting",
        sourceScopes: [`ha:https://ha.example.test:8123`, ACC_A],
        pausedCapabilities: ["xiaomi-cloud"],
      },
    ];
    app.scheduledCommandStore.persist();

    // Refresh HA while ACC_A is disabled, then re-enable ACC_A in HA mode and refresh HA again!
    await refreshDevices(app, false);
    const reenabledInHa = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 20_000 });
    assert.equal(reenabledInHa.status, "applied");
    await refreshDevices(app, false);

    const stateInHa = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [makeMiAccount(SESS_A)],
      haBaseURL: app.settings.haBaseURL,
      haToken: app.settings.haToken,
      connectionMode: "homeAssistant",
      dualSourceEnabled: false,
      hasExistingPreferences: true,
    });
    assert.equal(stateInHa.pendingRevalidationAccountIds.has(ACC_A), true, "ACC_A must stay pending until a real Xiaomi snapshot completes");
    assert.equal(stateInHa.pausedQuickActionIds.has("lightsOff"), true, "HA refresh must not unpause lightsOff from HA devices alone while Xiaomi revalidation is pending");
    assert.equal(miQueue.pausedScheduledCommands?.length, 3, "Xiaomi timers in miQueue must stay paused until Xiaomi snapshot refreshes");
    assert.equal(miQueue.missedScheduledCommands.length, 0, "HA refresh must not move still-valid Xiaomi timers to missed");
    assert.equal(haQueue.pausedScheduledCommands?.length, 1, "active-queue timer depending on pending Xiaomi scope must stay paused");
    assert.equal(haQueue.missedScheduledCommands.length, 0, "HA refresh must not move active-queue pending Xiaomi timer to missed");
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_dev")?.isEnabled, false);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_qa")?.isEnabled, false);

    // Now switch back to Xiaomi Cloud (with scene restored) and run Xiaomi refresh at nowMs + 120s -> pending revalidation completes!
    app.settings.connectionMode = "xiaomiCloud";
    app.scenes = [{ id: `${ACC_A}/sc_night`, accountId: ACC_A, sourceBackend: "xiaomiCloud", name: "米家晚安", entityId: "101.2.a1" }];
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await refreshDevices(app, false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    processScheduledCommands(app, nowMs + 120_000);
    assert.equal(executedMiCommands, 0, "expired timer must move to missed without auto-firing");
    assert.deepEqual(new Set(miQueue.scheduledCommands.map((t) => t.id)), new Set(["t_mi_valid_future", "t_mi_valid_scene"]));
    assert.deepEqual(miQueue.missedScheduledCommands.map((t) => t.id), ["t_mi_expired"]);
    assert.equal(miQueue.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_dev")?.isEnabled, true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_qa")?.isEnabled, true);
    const stateAfterXiaomiSync = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
    assert.equal(stateAfterXiaomiSync.pendingRevalidationAccountIds.has(ACC_A), false);
    assert.equal(stateAfterXiaomiSync.pausedQuickActionIds.has("lightsOff"), false);
  });
});



