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
import { resolveConnectionStatus } from "../src/ui/connectionStatus.js";
import {
  enqueueScheduledCommand,
  markTimerSnapshotReady,
  processScheduledCommands,
  scheduledCommandIdentity,
} from "../src/ui/scheduledCommands.js";
import { executeBuiltInQuickAction } from "../src/ui/speechGuard.js";
import { signOutAndRevokeAll } from "../src/ui/settingsEvents.js";
import { filterByListCut, orderAndAliasRooms } from "../src/ui/listCut.js";
import { onOpenURL } from "../src/core/appUrlCommand.js";
import { AutomationRuleStore, createAutomationRule } from "../src/core/automationEngine.js";
import { DualSourceCoordinator } from "../src/core/dualSourceProvider.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import { evaluateControlTargetGate } from "../src/core/capabilityReferenceVerdict.js";
import type { HomeScene } from "../src/core/models.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  buildIndexedCapabilityDevices,
  evaluateDeviceEntityWriteGate,
  evaluateDisabledSceneUrlGate,
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
    // The footer must tell the same story: Xiaomi is turned off, Home Assistant keeps the panel usable,
    // and no stale "米家账号 …" label promises a login that can no longer control anything.
    const status = resolveConnectionStatus(app);
    assert.notEqual(status.tone, "offline", "a disabled Xiaomi login must not take the Home Assistant panel down");
    assert.doesNotMatch(status.text, /米家账号/);
    assert.match(status.text, /米家已停用/);
    const miSource = status.sources.find((source) => source.id === "mi");
    assert.equal(miSource?.badge, "unconfigured");
    assert.match(miSource?.statusText ?? "", /米家已停用/);
    assert.equal(status.sources.find((source) => source.id === "ha")?.badge, "online");
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

    assert.deepEqual(app.multiAccountState?.merged?.deviceOwners["101"], [ACC_A, ACC_B]);
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

  it("releases paused timers into missedScheduledCommands and clears paused capabilities when signing out a disabled Xiaomi account across primary-switch, full sign-out, dual-source, and revoke-all flows (4623897070)", async () => {
    let executedMiWrites = 0;
    const makeTransport = (): HttpTransport => async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") {
        executedMiWrites += 1;
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: `Home-${user}`, roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "主号吸顶灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "202", name: "副号落地灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        const did = user === "10001" ? "101" : "202";
        return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    // Sub-flow A: Primary account ACC_A disabled (timers paused in ACC_A's queue), then signed out while ACC_B stays active (activeTimerIdentity switches to ACC_B!)
    const secureA = makeSecure();
    const appA = mountApp(makeTransport(), secureA);
    appA.settings.connectionMode = "xiaomiCloud";
    appA.settings.miSession = SESS_A;
    const storeA = getHostMiAccountsStore(appA);
    await storeA.upsertAccount(SESS_A);
    await storeA.upsertAccount(SESS_B);
    await refreshDevices(appA, false);
    markTimerSnapshotReady(appA);

    const nowMs = Date.now();
    const identityA = scheduledCommandIdentity(appA.settings)!;
    const queueA = appA.scheduledCommandStore.queue(identityA);
    queueA.scheduledCommands = [
      { id: "t_primary_future", command: "五分钟后关主号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t_primary_expired", command: "十秒后关主号灯", reply: "好", delaySeconds: 10, fireTimestampMs: nowMs - 5_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    appA.scheduledCommandStore.persist();
    const ruleStoreA = new AutomationRuleStore(localStorage);
    ruleStoreA.save([
      createAutomationRule({ id: "r_only_a", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "r_mixed_ab", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101", "202"], isOn: false } }),
    ]);

    const disabledPrimary = await setMiAccountEnabledOnHost(appA, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(disabledPrimary.status, "applied");
    assert.equal(queueA.pausedScheduledCommands?.length, 2);

    appA.openSettingsSheet("connection");
    const removeABtn = document.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${ACC_A}"]`);
    assert.ok(removeABtn, "expected sign-out button for primary account A");
    removeABtn.click();
    for (
      let i = 0;
      i < 40 && (storeA.getAccounts().some((a) => a.id === ACC_A) || (appA.connDiagSession?.signingOutAccountIds.size ?? 0) > 0);
      i += 1
    ) {
      await new Promise((r) => setTimeout(r, 0));
    }
    await new Promise((r) => setTimeout(r, 0));

    assert.notEqual(scheduledCommandIdentity(appA.settings), identityA, "activeTimerIdentity must switch away from signed-out ACC_A");
    assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0, "signed-out ACC_A queue must not keep paused timers stuck");
    assert.deepEqual(
      new Set(queueA.missedScheduledCommands.map((t) => t.id)),
      new Set(["t_primary_future", "t_primary_expired"]),
      "paused timers of signed-out ACC_A must release into missedScheduledCommands",
    );
    assert.equal(ruleStoreA.load().find((r) => r.id === "r_only_a")?.isEnabled, false);
    assert.equal(ruleStoreA.load().find((r) => r.id === "r_only_a")?.pausedByCapabilities, undefined, "signed-out account rule must clear stuck pausedByCapabilities");
    assert.equal(ruleStoreA.load().find((r) => r.id === "r_mixed_ab")?.isEnabled, false, "partial multi-device automation plan must not auto-resume when one target's account signed out");
    assert.equal(ruleStoreA.load().find((r) => r.id === "r_mixed_ab")?.pausedByCapabilities, undefined);

    // Sub-flow B: Dual-source & full signOutXiaomiAccount -> releases both active HA queue and inactive Xiaomi queue paused timers
    localStorage.clear();
    const secureB = makeSecure();
    const appB = mountApp(makeTransport(), secureB);
    appB.settings.connectionMode = "homeAssistant";
    appB.settings.haBaseURL = "https://ha.example.test:8123";
    appB.settings.haToken = "ha-tok";
    appB.settings.miSession = SESS_A;
    setHostDualSourceEnabled(appB, true, { persist: true });
    setHostHAInvokeOverride(appB, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA玄关灯" }],
          entities: [{ entity_id: "light.ha_hall", device_id: "ha-dev-1" }],
          states: [{ entity_id: "light.ha_hall", state: "on", attributes: { friendly_name: "HA玄关灯", brightness: 200 } }],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    await getHostMiAccountsStore(appB).upsertAccount(SESS_A);
    await refreshDevices(appB, false);
    markTimerSnapshotReady(appB);

    const haIdB = scheduledCommandIdentity(appB.settings)!;
    const haQueueB = appB.scheduledCommandStore.queue(haIdB);
    const miIdB = JSON.stringify(["xiaomiCloud", SESS_A.userId, "cn"]);
    const miQueueB = appB.scheduledCommandStore.queue(miIdB);
    const miOnlyDev = appB.devices.find((d) => d.name === "主号吸顶灯")!;
    assert.ok(miOnlyDev);
    haQueueB.scheduledCommands = [
      { id: "t_dual_ha_queue", command: "五分钟后关主号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: miOnlyDev.id, operation: { kind: "power", isOn: false } }], sourceScopes: ["ha:https://ha.example.test:8123", ACC_A] },
    ];
    miQueueB.scheduledCommands = [
      { id: "t_dual_mi_queue", command: "十分钟后关主号灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: miOnlyDev.id, operation: { kind: "power", isOn: false } }], sourceScopes: [ACC_A] },
    ];
    appB.scheduledCommandStore.persist();

    await setMiAccountEnabledOnHost(appB, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(haQueueB.pausedScheduledCommands?.length, 1);
    assert.equal(miQueueB.pausedScheduledCommands?.length, 1);

    signOutXiaomiAccount(appB);
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(haQueueB.pausedScheduledCommands?.length ?? 0, 0, "HA queue paused timer for signed-out Mi account must release");
    assert.equal(haQueueB.missedScheduledCommands.some((t) => t.id === "t_dual_ha_queue"), true);
    assert.equal(miQueueB.pausedScheduledCommands?.length ?? 0, 0, "Mi queue paused timer for signed-out Mi account must release");
    assert.equal(miQueueB.missedScheduledCommands.some((t) => t.id === "t_dual_mi_queue"), true);

    // Sub-flow C: Disabled Xiaomi account -> signOutAndRevokeAll releases paused timers into missedScheduledCommands
    localStorage.clear();
    const secureC = makeSecure();
    const appC = mountApp(makeTransport(), secureC);
    appC.settings.connectionMode = "xiaomiCloud";
    appC.settings.miSession = SESS_A;
    await getHostMiAccountsStore(appC).upsertAccount(SESS_A);
    await refreshDevices(appC, false);
    markTimerSnapshotReady(appC);
    const miIdC = scheduledCommandIdentity(appC.settings)!;
    const miQueueC = appC.scheduledCommandStore.queue(miIdC);
    miQueueC.scheduledCommands = [
      { id: "t_revoke_all", command: "五分钟后关主号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    appC.scheduledCommandStore.persist();
    await setMiAccountEnabledOnHost(appC, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(miQueueC.pausedScheduledCommands?.length, 1);

    await signOutAndRevokeAll(appC);
    assert.equal(miQueueC.pausedScheduledCommands?.length ?? 0, 0, "signOutAndRevokeAll must release paused Xiaomi timers");
    assert.equal(miQueueC.missedScheduledCommands.some((t) => t.id === "t_revoke_all"), true);
    assert.equal(executedMiWrites, 0, "releasing paused timers on sign-out must never fire hardware writes");
  });

  it("snapshots disabled Xiaomi scenes so direct activateScene writes, intent gates, and scene URL commands reject as disabled instead of hitting cloud or reporting missing (4623897082)", async () => {
    const cloudWrites: string[] = [];
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action" || path.includes("scene")) {
        cloudWrites.push(path);
        return okMi({ code: 0 });
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "101", name: "客厅灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);
    await refreshDevices(app, false);
    const miSceneId = `${ACC_A}/sc_mi_night`;
    app.scenes = [{ id: miSceneId, name: "米家晚安", entityId: "101.2.a1", accountId: ACC_A, sourceBackend: "xiaomiCloud" }];

    const disOutcome = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(disOutcome.status, "applied");
    assert.equal(app.scenes.length, 0, "disabled Xiaomi scene must be stripped from active host.scenes");

    // 1. Direct applyCommand({ kind: "activateScene" }) by entityId and by scene id must be blocked by disable gate with zero cloud writes!
    const directByEntity = await app.applyCommand({ kind: "activateScene", entityId: "101.2.a1" });
    assert.equal(directByEntity, false, "direct activateScene by entityId must be rejected when Xiaomi account is disabled");
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);

    const directById = await app.applyCommand({ kind: "activateScene", entityId: miSceneId });
    assert.equal(directById, false, "direct activateScene by sceneId must be rejected when Xiaomi account is disabled");
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);

    // 2. evaluateIntentsWriteGate without manually re-injecting app.scenes must still reject disabled Xiaomi scene!
    const gateMsg = evaluateIntentsWriteGate({
      intents: [{ targetId: miSceneId, operation: { kind: "activateScene" } }],
      context: buildHostCapabilityContext(app, [makeMiAccount(SESS_A)]),
    });
    assert.match(gateMsg ?? "", /该米家账号已停用/);

    // 3. URL scene command by name and by id must report disabled Xiaomi account instead of missing!
    const urlToasts: string[] = [];
    const makeUrlHost = () => ({
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
      showExternalToast: (msg: string) => { urlToasts.push(msg); },
      recordRaycastCommandFeedback: () => {},
      executeSingleCommand: (d: never, c: never, s: never, i: never, r: never) => app.executeSingleCommand(d, c, s, i, r),
      applyCommand: (c: never, r: never) => app.applyCommand(c, r),
      updateUndoCommandsForDevice: () => {},
      handleNaturalCommand: (u: string, f?: boolean) => app.handleNaturalCommand(u, f),
      executeBuiltInSceneFromUrl: async () => ({ message: "", isError: false }),
      focusDeviceFromUrl: () => "focused" as const,
    });

    await onOpenURL(`menumijia://scene?name=${encodeURIComponent("米家晚安")}`, makeUrlHost());
    assert.match(urlToasts.at(-1) ?? "", /该米家账号已停用/);

    setLanguage("en");
    await onOpenURL(`menumijia://scene?name=${encodeURIComponent(miSceneId)}`, makeUrlHost());
    assert.match(urlToasts.at(-1) ?? "", /This Xiaomi account is turned off/);
    setLanguage("zh-Hans");

    await onOpenURL(`menumijia://scene?name=${encodeURIComponent("不存在的虚构场景")}`, makeUrlHost());
    assert.match(urlToasts.at(-1) ?? "", /不存在|尚未加载/);
    assert.deepEqual(cloudWrites, []);

    // 4. Re-enabling cleans up knownDisabledScenes after refresh completes
    const reenabled = await setMiAccountEnabledOnHost(app, ACC_A, true);
    assert.equal(reenabled.status, "applied");
    const rawAfterReenable = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as Record<string, unknown>;
    assert.equal(rawAfterReenable["knownDisabledScenes"], undefined, "knownDisabledScenes must be cleaned up after re-enable refresh");
  });

  it("snapshots dual-source Xiaomi scenes that only live on the coordinator or multi-account children so disabled-account gates reject instead of failing open (4624246983)", async () => {
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: `Home-${user}`, roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return user === "10001"
          ? okMi({ list: [{ did: "101", name: "米家书房灯", model: LIGHT_MODEL, isOnline: true }] })
          : okMi({ list: [{ did: "201", name: "米家卧室灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([
          { did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 },
          { did: "201", siid: 2, piid: 1, code: 0, value: true }, { did: "201", siid: 2, piid: 2, code: 0, value: 60 },
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
    setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
      if (cmd === "ha_snapshot") {
        return ({
          areas: [],
          devices: [{ id: "ha-dev-1", name: "HA客厅灯" }],
          entities: [{ entity_id: "light.ha_living", device_id: "ha-dev-1" }],
          states: [
            { entity_id: "light.ha_living", state: "on", attributes: { friendly_name: "HA客厅灯", brightness: 120 } },
            { entity_id: "scene.ha_movie", state: "on", attributes: { friendly_name: "HA观影" } },
          ],
        } as unknown) as T;
      }
      return (null as unknown) as T;
    });
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    // The dual-source merge copies only Home Assistant scenes into host.scenes; Xiaomi scenes stay
    // on the coordinator's Mi snapshot and on the multi-account child/merged snapshots.
    assert.deepEqual(app.scenes.map((s) => s.id), ["scene.ha_movie"], "dual-source host.scenes must stay Home-Assistant-only here");
    const multiState = app.multiAccountState!;
    const childA = multiState.children[ACC_A]!, childB = multiState.children[ACC_B]!;
    assert.ok(childA && childB && multiState.merged);

    const miSceneFromLastMi: HomeScene = { id: "mi_scene_night", name: "米家晚安", entityId: "101.2.a1" };
    const miSceneFromChild: HomeScene = { id: "mi_scene_noon", name: "米家午休", entityId: "101.2.a2", accountId: ACC_A, sourceBackend: "xiaomiCloud" };
    const miSceneFromChildB: HomeScene = { id: "mi_scene_bedroom", name: "米家次卧", entityId: "201.2.a1", accountId: ACC_B, sourceBackend: "xiaomiCloud" };

    app.multiAccountState = {
      accounts: multiState.accounts,
      merged: { ...multiState.merged!, home: { ...multiState.merged!.home, scenes: [miSceneFromChild, miSceneFromChildB] } },
      children: {
        [ACC_A]: { ...childA, home: { ...childA.home, scenes: [miSceneFromChild] } },
        [ACC_B]: { ...childB, home: { ...childB.home, scenes: [miSceneFromChildB] } },
      },
    };

    const coordinator = app.dualSourceCoordinator!;
    const mergedHome = app.multiAccountState.merged!.home;
    await coordinator.refreshParallel({
      fetchHA: async () => coordinator.getLastHASnapshot()!,
      fetchMi: async () => ({
        home: { ...mergedHome, scenes: [miSceneFromLastMi] },
        homes: app.multiAccountState!.merged!.homes,
        accountStatuses: app.multiAccountState!.merged!.accountStatuses,
      }),
    });
    assert.equal(coordinator.getLastMerged()?.home.scenes.some((s) => s.id === miSceneFromLastMi.id) ?? false, false,
      "dual-source merge drops Xiaomi scenes from merged.home.scenes — the scene collector has to read the Mi snapshot");

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_mi_dual_scene", isEnabled: true, trigger: "screenLocked", action: { kind: "scene", sceneId: miSceneFromChild.id } }),
    ]);

    // Preflight/capability indexing must see the Xiaomi scenes even though host.scenes is HA-only.
    const preflight = buildHostCapabilityContext(app, [makeMiAccount(SESS_A), makeMiAccount(SESS_B)]);
    assert.deepEqual(
      new Set(preflight.scenes.map((s) => s.id)),
      new Set(["scene.ha_movie", miSceneFromLastMi.id, miSceneFromChild.id, miSceneFromChildB.id]),
      "capability context must merge HA scenes with Xiaomi scenes from the coordinator and multi-account snapshots",
    );

    const preview = await setMiAccountEnabledOnHost(app, ACC_A, false);
    assert.equal(preview.status, "requiresPauseConfirmation", "dual-source Xiaomi scene automation must require pause confirmation");
    const applied = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(applied.status, "applied");
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_dual_scene")?.isEnabled, false, "rule on the disabled account's Xiaomi scene must pause");

    const raw = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as {
      knownDisabledScenes?: Array<{ id: string; accountId: string }>;
    };
    const snapshots = raw.knownDisabledScenes ?? [];
    assert.equal(snapshots.some((s) => s.id === miSceneFromLastMi.id), true, "Xiaomi scene cached only on the coordinator must be snapshotted");
    assert.equal(snapshots.some((s) => s.id === miSceneFromChild.id), true, "Xiaomi scene cached on a multi-account child must be snapshotted");
    assert.equal(snapshots.find((s) => s.id === miSceneFromLastMi.id)?.accountId, ACC_A, "snapshot must be attributed to the disabled account");
    assert.equal(snapshots.some((s) => s.id === miSceneFromChildB.id), false, "surviving account's Xiaomi scene must not be snapshotted");
    assert.deepEqual(app.scenes.map((s) => s.id), ["scene.ha_movie"], "HA scenes must stay on the panel after disabling the Xiaomi account");

    const ctx = buildHostCapabilityContext(app, [makeMiAccount(SESS_A), makeMiAccount(SESS_B)]);
    // 1. Direct entity write gate by Xiaomi entityId/id rejects as disabled instead of failing open.
    assert.match(
      evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromLastMi.entityId, resolvedActiveDeviceId: null, context: ctx }) ?? "",
      /该米家账号已停用/,
      "direct scene write by entityId must report the disabled Xiaomi account",
    );
    assert.match(
      evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromChild.id, resolvedActiveDeviceId: null, context: ctx }) ?? "",
      /该米家账号已停用/,
      "direct scene write by scene id must report the disabled Xiaomi account",
    );
    // 2. Low-level control gate resolves the snapshotted scene and rejects on the disabled scope.
    const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(ctx);
    const controlGate = evaluateControlTargetGate({ targetKind: "scene", targetId: miSceneFromChild.id, selection: ctx.state.selection, devices: indexedDevices, scenes: sceneRefs });
    assert.equal(controlGate.allowed, false);
    assert.equal(controlGate.rejectionReason?.code, "connectionScopeDisabled", "disabled Xiaomi scene must not degrade to sceneNotFound");
    // 3. Scene URL activation by name and by id reports the disabled account instead of "不存在".
    assert.match(evaluateDisabledSceneUrlGate("米家晚安", app.settings) ?? "", /该米家账号已停用/);
    assert.match(evaluateDisabledSceneUrlGate(miSceneFromChild.id, app.settings) ?? "", /该米家账号已停用/);
    // 4. Home Assistant scenes and the surviving Xiaomi account stay unaffected.
    assert.equal(evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: "scene.ha_movie", resolvedActiveDeviceId: null, context: ctx }), null);
    assert.equal(evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromChildB.id, resolvedActiveDeviceId: null, context: ctx }), null);
  });

  it("aborts Xiaomi account re-enable when capability selection persistence fails so UI rolls back and paused items still revalidate on retry (4623897095)", async () => {
    let refreshRequests = 0;
    const secure = makeSecure();
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        refreshRequests += 1;
        return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [{ did: "101", name: "卧室灯", model: LIGHT_MODEL, isOnline: true }] });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0, value: true }, { did: "101", siid: 2, piid: 2, code: 0, value: 80 }]);
      }
      return okMi({});
    };

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    const miQueue = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    miQueue.scheduledCommands = [
      { id: "t_reenable_fail", command: "五分钟后关卧室灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_reenable_fail", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
    ]);

    const disabled = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(disabled.status, "applied");
    app.openSettingsSheet("connection");
    const toggleBox = () => document.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`);
    assert.equal(toggleBox()?.checked, false);

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
    const refreshBeforeFail = refreshRequests;
    try {
      // 1) Non-demo re-enable failure -> blocked, zero refresh calls, error banner & inline error, checkbox rolled back to unchecked!
      const box = toggleBox()!;
      box.checked = true;
      const failedLive = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 10_000 });
      assert.equal(failedLive.status, "blocked", "re-enable must not return applied when persistence fails");
      assert.equal(refreshRequests, refreshBeforeFail, "re-enable must not refresh cloud while account remains disabled on disk");
      assert.equal(app.replyBanner?.isError, true);
      assert.ok(document.querySelector(`[data-mi-account-disable-error="${ACC_A}"]`), "expected inline error on re-enable persist failure");
      assert.equal(toggleBox()?.checked, false, "account toggle must roll back to unchecked when persist fails");
      assert.equal(miQueue.pausedScheduledCommands?.length, 1);

      // 2) Demo mode re-enable failure -> also blocked without unpausing items while disk still marks account disabled!
      app.settings.connectionMode = "demo";
      const failedDemo = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 10_000 });
      assert.equal(failedDemo.status, "blocked");
      assert.equal(miQueue.pausedScheduledCommands?.length, 1, "demo re-enable persist failure must not prematurely unpause timers");
      assert.equal(ruleStore.load()[0]?.isEnabled, false);
      app.settings.connectionMode = "xiaomiCloud";
    } finally {
      failCapabilityWrite = false;
      Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: origSetItem });
    }

    // 3) Retry after storage recovers -> succeeds, refreshes, clears error, and revalidates paused timer + rule + quickAction!
    const retried = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 20_000 });
    assert.equal(retried.status, "applied");
    assert.equal(toggleBox()?.checked, true);
    assert.equal(document.querySelector(`[data-mi-account-disable-error="${ACC_A}"]`), null);
    assert.equal(miQueue.pausedScheduledCommands?.length ?? 0, 0);
    assert.deepEqual(miQueue.scheduledCommands.map((t) => t.id), ["t_reenable_fail"]);
    assert.equal(ruleStore.load()[0]?.isEnabled, true);
    assert.equal(resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true }).pausedQuickActionIds.has("lightsOff"), false);
  });
});



