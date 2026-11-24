import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { canRefreshDevicesInBackground, signOutXiaomiAccount } from "../src/ui/appLifecycle.js";
import {
  applyMiotTypePruneSnapshot,
  buildHostCapabilityContext,
  dropMiotTypePruneSnapshotForAccount,
  getHostDualSourceCoordinator,
  getHostMiAccountsStore,
  hostMiotTypePruneOptions,
  recomputeHostDualSource,
  refreshDevices,
  setHostDeviceSourcePin,
  setHostDualSourceEnabled,
  setHostHAInvokeOverride,
} from "../src/ui/cloudRefresh.js";
import { scheduleEchoReadBack } from "../src/ui/commandDispatch.js";
import { addOrUpdateMiAccountOnHost, setMiAccountEnabledOnHost } from "../src/ui/connectionsAndDiagView.js";
import { saveSafetyGuardPrefs } from "../src/ui/automationSettingsView.js";
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
import { makeMiAccount, mergeMiAccountSnapshots } from "../src/core/miAccountsStore.js";
import { saveSensorAlertPolicy } from "../src/core/safetyAndHealth.js";
import { evaluateControlTargetGate, type CapabilityIndexedDevice } from "../src/core/capabilityReferenceVerdict.js";
import type { FacetControl, HomeScene, SmartDevice } from "../src/core/models.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  buildIndexedCapabilityDevices,
  evaluateDeviceEntityWriteGate,
  evaluateDisabledSceneUrlGate,
  evaluateIntentsWriteGate,
  filterEnabledMiAccounts,
  miAccountScope,
  resolveHiddenTypeDeviceByEntity,
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
const MOISTURE_MODEL = "bkxh.flood.yf02";

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
const MOISTURE_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:flood-sensor:0000A021:bkxh-yf02:1",
  description: "Flood Sensor",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:flood-sensor:00007827:bkxh-yf02:1",
      description: "Flood Sensor",
      properties: [{ iid: 1001, type: "urn:miot-spec-v2:property:water-leak:0000001A:bkxh-yf02:1", description: "Water Leak", format: "bool", access: ["read", "notify"] }],
      actions: [],
    },
    {
      iid: 3,
      type: "urn:miot-spec-v2:service:battery:00007805:bkxh-yf02:1",
      description: "Battery",
      properties: [{ iid: 1, type: "urn:miot-spec-v2:property:battery-level:00000010:bkxh-yf02:1", description: "Battery Level", format: "uint8", access: ["read", "notify"] }],
      actions: [],
    },
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
    [LIGHT_MODEL]: LIGHT_SPEC, [HEATER_PLUG_MODEL]: PLUG_SPEC, [CAM_MODEL]: CAM_SPEC, [MOISTURE_MODEL]: MOISTURE_SPEC,
  });
  (app as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secure.invoke);
  app.miAccountsStore = null;
  app.settings.hasCompletedOnboarding = true;
  app.activeSheet = "none";
  app.timerCredentialsReady = true;
  return app;
}

function makeBasicMiTransport(opts: {
  did?: string;
  name?: string;
  secName?: string;
  writes?: string[];
  onBefore?: (user: string, path: string) => Promise<void> | void;
} = {}): HttpTransport {
  const primaryDid = opts.did ?? "101";
  const primaryName = opts.name ?? "书房台灯";
  const secName = opts.secName ?? "副号落地灯";
  return async (req) => {
    const user = reqUser(req), path = reqPath(req);
    await opts.onBefore?.(user, path);
    if (path === "miotspec/prop/set" || path === "miotspec/action" || path.includes("scene")) {
      opts.writes?.push(path);
      return okMi([{ did: primaryDid, siid: 2, piid: 1, code: 0 }]);
    }
    if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
      return okMi({ homelist: [{ id: user === "20002" ? "9202" : "9101", name: `Home-${user || "10001"}`, roomlist: [] }] });
    }
    if (path === "v2/home/device_list_page" || path === "home/device_list") {
      return user === "20002"
        ? okMi({ list: [{ did: "202", name: secName, model: LIGHT_MODEL, isOnline: true }] })
        : okMi({ list: [{ did: primaryDid, name: primaryName, model: LIGHT_MODEL, isOnline: true }] });
    }
    if (path === "miotspec/prop/get") {
      const did = user === "20002" ? "202" : primaryDid;
      return okMi([{ did, siid: 2, piid: 1, code: 0, value: true }, { did, siid: 2, piid: 2, code: 0, value: 80 }]);
    }
    return okMi({});
  };
}

function installSimpleHaLight(app: MenuMijiaWindowsApp, name = "HA客厅灯", entityId = "light.ha_living", onExec?: () => void): void {
  setHostHAInvokeOverride(app, async <T>(cmd: string): Promise<T> => {
    if (cmd === "ha_snapshot") {
      return ({
        areas: [{ area_id: "ha_living", name: "HA客厅" }],
        devices: [{ id: "ha-dev-1", area_id: "ha_living", name }],
        entities: [{ entity_id: entityId, device_id: "ha-dev-1" }],
        states: [{ entity_id: entityId, state: "on", attributes: { friendly_name: name, brightness: 200 } }],
      } as unknown) as T;
    }
    if (cmd === "ha_execute") onExec?.();
    return (null as unknown) as T;
  });
}

function makeUrlHost(app: MenuMijiaWindowsApp, urlToasts: string[]) {
  return {
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
  };
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

    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, "{not-valid-json");
    const corrupted = resolveMiAccountSelectionState({ storage: localStorage, accounts, hasExistingPreferences: true });
    assert.equal(corrupted.mode, "uncertainFallback");
    assert.equal(filterEnabledMiAccounts(accounts, corrupted).length, 2);
    assert.equal(corrupted.persistIfMigrationReady(), false);
    assert.equal(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY), "{not-valid-json");

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
    assert.equal(calls.some((c) => c.user === "20002"), false);
    assert.equal(calls.some((c) => c.user === "10001"), true);

    recordXiaomiRateLimit(app, SESS_A);
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(getXiaomiBackoffUntilMs(app, SESS_A), null);
    assert.equal(canRefreshDevicesInBackground(app), false);
    calls.length = 0;
    await refreshDevices(app, false);
    assert.equal(calls.length, 0);
    assert.equal(app.devices.length, 0);

    app.settings.haBaseURL = "http://homeassistant.local:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    let haCalls = 0;
    installSimpleHaLight(app, "HA客厅灯", "light.ha_living", () => {});
    const prevOverride = app.haInvokeOverride!;
    setHostHAInvokeOverride(app, async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> => {
      if (cmd === "ha_snapshot") haCalls += 1;
      return prevOverride<T>(cmd, args);
    });
    await refreshDevices(app, false);
    assert.equal(haCalls, 1);
    assert.equal(calls.length, 0);
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

    const transport = makeBasicMiTransport({
      name: "书房灯",
      onBefore: async (_user, path) => {
        if (disabled) callsAfterDisable.push(path);
        if (path.includes("homeroom") || path.includes("device_list")) await refreshGate;
      },
    });

    const app = mountApp(transport, secure);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.devices = [
      { id: "101", name: "书房灯", roomId: "r1", roomName: "书房", model: LIGHT_MODEL, isOnline: true, sourceBackend: "xiaomiCloud", kind: { kind: "light", entityId: "101.2.1", isOn: true, brightnessPercent: 60, colorTempKelvin: null, minKelvin: 2700, maxKelvin: 6500, availableEffects: [], currentEffect: null } },
      { id: "109", name: "玄关摄像机", roomId: "r1", roomName: "玄关", model: CAM_MODEL, isOnline: true, sourceBackend: "xiaomiCloud", kind: { kind: "camera", entityId: "109.2.1", isOn: true, powerWritable: true, nightShot: null, availableNightShots: [], motionDetectionEntityId: null, isMotionDetectionOn: null, streamEntityId: null, lenses: [] } },
    ];

    const inFlightRefresh = refreshDevices(app, true);
    scheduleEchoReadBack(app, "101", null, 20);
    let delayedFired = false;
    scheduleDelayedReadBack(app, "101", 20, () => { delayedFired = true; });
    (app as unknown as { specResolver: { resolve: () => Promise<typeof CAM_SPEC> } }).specResolver = {
      resolve: async () => { await specGate; return CAM_SPEC; },
    };
    app.cameraLive.activeLiveCameraId = "109";
    const inFlightCam = app.cameraLive.resolveCloudCameraStream(app.devices[1]!);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    disabled = true;
    const tauriCountAtDisable = secure.tauriCalls.filter((c) => c.cmd === "start_xiaomi_camera_bridge").length;

    releaseRefresh();
    releaseSpec();
    await inFlightRefresh;
    await inFlightCam;
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(callsAfterDisable, []);
    assert.equal(delayedFired, false);
    assert.equal(secure.tauriCalls.filter((c) => c.cmd === "start_xiaomi_camera_bridge").length, tauriCountAtDisable);
    assert.equal(app.devices.length, 0);
    assert.equal(app.settings.cachedXiaomiDevices.length, 0);
  });

  it("previews affected timers/automations/quickActions, pauses on confirm, revalidates on re-enable without auto-firing expired timers, and defers revalidation on failed snapshot", async () => {
    let activeDids = ["101", "102"];
    let failMiNetwork = false;
    const writes: string[] = [];
    const transport: HttpTransport = async (req) => {
      if (failMiNetwork) throw new Error("network down");
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
    const queueA = app.scheduledCommandStore.queue(idA);
    queueA.scheduledCommands = [
      { id: "timer_expire", command: "关书房台灯", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "timer_future", command: "调亮书房台灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "brightness", percent: 90 } }] },
      { id: "timer_deleted", command: "关备用台灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "102", operation: { kind: "power", isOn: false } }] },
    ];
    queueA.missedScheduledCommands = [
      { id: "timer_missed", command: "早先错过", reply: "好", delaySeconds: 30, fireTimestampMs: nowMs - 10_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
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

    const preview = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(preview.status, "requiresPauseConfirmation");
    if (preview.status === "requiresPauseConfirmation") {
      const kinds = new Set(preview.verdict.itemsToPause.map((i) => `${i.kind}:${i.id}`));
      assert.equal(kinds.has("waitingTimer:timer_expire"), true);
      assert.equal(kinds.has("missedTimer:timer_missed"), true);
      assert.equal(kinds.has("automationRule:rule_on"), true);
      assert.equal(kinds.has("automationRule:rule_user_off"), false);
      assert.equal(kinds.has("quickAction:lightsOff"), true);
    }
    assert.equal(app.devices.length, 2);

    const confirmed = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(confirmed.status, "applied");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "rule_on")?.isEnabled, false);

    processScheduledCommands(app, nowMs + 120_000);
    await executeBuiltInQuickAction(app, "lightsOff");
    assert.deepEqual(writes, []);

    activeDids = ["101"];
    failMiNetwork = true;
    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(queueA.pausedScheduledCommands?.length, 4);
    assert.equal(ruleStore.load().find((r) => r.id === "rule_on")?.isEnabled, false);

    failMiNetwork = false;
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await refreshDevices(app, false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    assert.deepEqual(writes, []);
    assert.deepEqual(app.scheduledCommands.map((t) => t.id), ["timer_future"]);
    assert.deepEqual(new Set(app.missedScheduledCommands.map((t) => t.id)), new Set(["timer_missed", "timer_expire", "timer_deleted"]));
    assert.equal(ruleStore.load().find((r) => r.id === "rule_on")?.isEnabled, true);
    assert.equal(ruleStore.load().find((r) => r.id === "rule_user_off")?.isEnabled, false);
    assert.equal(resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true }).pausedQuickActionIds.has("lightsOff"), false);
  });

  it("gates control writes before confirmation, distinguishes disabled Xiaomi account from nonexistent device, and matches URL identifiers by entity id, miot form, and normalized name", async () => {
    const writes: string[] = [];
    const transport: HttpTransport = async (req) => {
      const path = reqPath(req);
      if (path === "miotspec/prop/set" || path === "miotspec/action") writes.push(path);
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") return okMi({ homelist: [{ id: "9101", name: "Home", roomlist: [] }] });
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({ list: [
          { did: "101", name: "Desk 书房台灯", model: LIGHT_MODEL, isOnline: true },
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
    const light = app.devices.find((d) => d.name === "Desk 书房台灯")!;
    const lightEntityId = light.kind.kind === "light" ? light.kind.entityId : "101.2.1";
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });

    const okDisabled = await app.executeIntents(
      [{ targetId: "105", operation: { kind: "power", isOn: true } }],
      "打开电暖器插座",
      "测试",
    );
    assert.equal(okDisabled, false);
    assert.equal(app.pendingHighRisk, null);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);

    const okMissing = await app.executeIntents(
      [{ targetId: "999404", operation: { kind: "power", isOn: true } }],
      "打开不存在设备",
      "测试",
    );
    assert.equal(okMissing, false);
    assert.match(app.replyBanner?.text ?? "", /设备不存在/);

    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "101.2.1", isOn: true }), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);

    setLanguage("en");
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "101.2.1", isOn: true }), false);
    assert.match(app.replyBanner?.text ?? "", /This Xiaomi account is turned off/);
    setLanguage("zh-Hans");

    const urlToasts: string[] = [];
    const miotForm = `miot:101:${lightEntityId.split(".").slice(1).join(".")}`;
    for (const identifier of [lightEntityId, miotForm, "Desk 书房台灯", "desk  书房台灯", "101"]) {
      urlToasts.length = 0;
      await onOpenURL(`menumijia://toggle?device=${encodeURIComponent(identifier)}`, makeUrlHost(app, urlToasts));
      assert.match(urlToasts.at(-1) ?? "", /该米家账号已停用/);
      assert.doesNotMatch(urlToasts.at(-1) ?? "", /不存在|尚未加载|不在面板中/);
    }
    urlToasts.length = 0;
    await onOpenURL(`menumijia://toggle?device=${encodeURIComponent("999404.2.1")}`, makeUrlHost(app, urlToasts));
    assert.match(urlToasts.at(-1) ?? "", /不存在|尚未加载|不在面板中/);
    assert.deepEqual(writes, []);
  });

  it("renders minimal 连接 toggle, human-readable preview names with 等 suffix, checks preview generation before confirming, and gives trilingual feedback for paused quick actions", async () => {
    const app = mountApp(makeBasicMiTransport());
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

    app.openSettingsSheet("connection");
    const connPanel = document.querySelector<HTMLElement>('[data-settings-panel="connection"]')!;
    assert.match(connPanel.textContent ?? "", /连接/);
    const toggle = connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)!;
    assert.equal(toggle.checked, true);

    toggle.checked = false;
    toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));

    const previewBox = connPanel.querySelector<HTMLElement>(`[data-mi-account-pause-preview="${ACC_A}"]`)!;
    assert.match(previewBox.textContent ?? "", /暂停这些项并关闭/);
    assert.doesNotMatch(previewBox.textContent ?? "", /rule_1712345678|lightsOff/);
    assert.match(previewBox.textContent ?? "", /等/);

    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-cancel-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)?.checked, true);

    const toggle2 = connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)!;
    toggle2.checked = false;
    toggle2.dispatchEvent(new window.Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));

    app.scheduledCommands.push({
      id: "t_gen_2", command: "新加关灯二", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }],
    });
    app.scheduledCommandStore.persist();

    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-confirm-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(app.scheduledCommands.length, 3);
    const updatedPreview = connPanel.querySelector<HTMLElement>(`[data-mi-account-pause-preview="${ACC_A}"]`)!;
    assert.match(updatedPreview.textContent ?? "", /新加关灯二/);

    connPanel.querySelector<HTMLButtonElement>(`[data-mi-account-confirm-disable="${ACC_A}"]`)!.click();
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(connPanel.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`)?.checked, false);

    const readBannerText = (): string => app.replyBanner?.text ?? "";
    for (const [lang, expected] of [
      ["zh-Hans", /全屋关灯.*连接/],
      ["zh-Hant", /全屋關燈.*連線/],
      ["en", /All Lights Off.*connection/i],
    ] as const) {
      setLanguage(lang);
      app.replyBanner = null;
      await executeBuiltInQuickAction(app, "lightsOff");
      assert.match(readBannerText(), expected);
    }
    setLanguage("zh-Hans");
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
      if (cmd === "ha_execute") haExecutes.push(args);
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    assert.equal(app.devices.length, 3);
    const haOnly = app.devices.find((d) => d.name === "HA独占落地灯")!;
    const mergedCard = app.devices.find((d) => d.name === "客厅主灯")!;
    const miOnlyBefore = app.devices.find((d) => d.name === "米家独占灯")!;
    assert.ok(haOnly && mergedCard && miOnlyBefore);

    const disabled = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.equal(disabled.status, "applied");
    assert.equal(app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind, "disconnected");

    await refreshDevices(app, false);
    assert.equal(app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind, "disconnected");
    const status = resolveConnectionStatus(app);
    assert.notEqual(status.tone, "offline");
    assert.doesNotMatch(status.text, /米家账号/);
    assert.match(status.text, /米家已停用/);
    assert.equal(status.sources.find((s) => s.id === "mi")?.badge, "unconfigured");
    assert.equal(status.sources.find((s) => s.id === "ha")?.badge, "online");

    const haEntity = haOnly.kind.kind === "light" ? haOnly.kind.entityId : "";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: haEntity, isOn: false }), true);
    assert.equal(await app.executeIntents([{ targetId: haOnly.id, operation: { kind: "power", isOn: true } }], "开HA独占灯", "测试"), true);
    assert.equal(haExecutes.length, 2);

    const mergedAfter = app.devices.find((d) => d.name === "客厅主灯")!;
    const mergedEntity = mergedAfter.kind.kind === "light" ? mergedAfter.kind.entityId : "";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: mergedEntity, isOn: false }), true);
    assert.equal(await app.executeIntents([{ targetId: mergedAfter.id, operation: { kind: "power", isOn: true } }], "开客厅主灯", "测试"), true);
    const urlToasts: string[] = [];
    await onOpenURL(`menumijia://power?device=${encodeURIComponent(mergedAfter.id)}&state=off`, makeUrlHost(app, urlToasts));
    assert.equal(haExecutes.length, 5);

    const miEntity = miOnlyBefore.kind.kind === "light" ? miOnlyBefore.kind.entityId : "102.2.1";
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: miEntity, isOn: false }), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.equal(await app.executeIntents([{ targetId: miOnlyBefore.id, operation: { kind: "power", isOn: true } }], "开米家独占灯", "测试"), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.deepEqual(miWrites, []);
    assert.equal(haExecutes.length, 5);
  });

  it("includes paused timers when cancelling all timers via 取消所有定时", async () => {
    const app = mountApp(makeBasicMiTransport());
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

    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 0);
  });

  it("prevents in-flight dual-source refresh from contaminating DualSourceCoordinator cache and preserves dual-source timer scopes across disable/re-enable", async () => {
    let gateEnabled = false;
    let releaseMi!: () => void;
    const miGate = new Promise<void>((r) => { releaseMi = r; });
    const app = mountApp(
      makeBasicMiTransport({
        did: "102",
        name: "米家书房灯",
        onBefore: async (_user, path) => {
          if (gateEnabled && path.includes("device_list")) await miGate;
        },
      }),
    );
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    installSimpleHaLight(app);

    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), true);

    const nowMs = Date.now();
    assert.equal(
      enqueueScheduledCommand(app, {
        id: "dual_enqueued", command: "五分钟后关米家书房灯", reply: "好", delaySeconds: 300,
        fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "102", operation: { kind: "power", isOn: false } }],
      }),
      true,
    );
    app.scheduledCommands.push({
      id: "dual_legacy", command: "十分钟后调亮米家书房灯", reply: "好", delaySeconds: 600,
      fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "102", operation: { kind: "brightness", percent: 90 } }],
    });
    app.scheduledCommandStore.persist();

    gateEnabled = true;
    const inFlight = refreshDevices(app, true);
    await new Promise((r) => setTimeout(r, 0));
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), false);
    assert.equal(app.scheduledCommands.length, 0);

    gateEnabled = false;
    releaseMi();
    await inFlight;

    setHostDeviceSourcePin(app, "light.ha_living", "homeAssistant");
    recomputeHostDualSource(app);
    assert.equal(app.devices.some((d) => d.name === "米家书房灯"), false);
    assert.equal(app.dualSourceCoordinator?.getLastMerged()?.home.devices.some((d) => d.name === "米家书房灯") ?? false, false);
    assert.equal(app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud.kind, "disconnected");

    const reenabled = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 10_000 });
    assert.equal(reenabled.status, "applied");
    assert.deepEqual(new Set(app.scheduledCommands.map((t) => t.id)), new Set(["dual_enqueued", "dual_legacy"]));
    assert.equal(app.missedScheduledCommands.length, 0);
  });

  it("rolls back atomically on disable/re-enable storage write failures, keeps pendingRevalidationAccountIds until all stores persist, and displays trilingual blocked banners", async () => {
    let refreshRequests = 0;
    const secure = makeSecure();
    const app = mountApp(
      makeBasicMiTransport({
        name: "主号台灯",
        onBefore: (_user, path) => {
          if (path.includes("homeroom")) refreshRequests += 1;
        },
      }),
      secure,
    );
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
      { id: "t_atomic", command: "关主号台灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: devAId, operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "rule_atomic", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: [devAId], isOn: false } }),
    ]);

    const origSetItem = localStorage.setItem.bind(localStorage);
    let blockedKey: string | null = MI_ACCOUNT_CAPABILITY_STORAGE_KEY;
    Object.defineProperty(localStorage, "setItem", {
      configurable: true,
      writable: true,
      value: (key: string, val: string): void => {
        if (blockedKey !== null && key === blockedKey) throw new Error("QuotaExceededError");
        origSetItem(key, val);
      },
    });
    try {
      const outcome = await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
      assert.equal(outcome.status, "blocked");
      assert.equal(app.scheduledCommands.length, 1);
      assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0);
      assert.equal(ruleStore.load()[0]?.isEnabled, true);
      assert.equal(app.replyBanner?.isError, true);

      blockedKey = null;
      await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
      assert.equal(queueA.pausedScheduledCommands?.length, 1);
      app.openSettingsSheet("connection");
      const toggleBox = () => document.querySelector<HTMLInputElement>(`[data-mi-account-enabled="${ACC_A}"]`);
      assert.equal(toggleBox()?.checked, false);

      blockedKey = MI_ACCOUNT_CAPABILITY_STORAGE_KEY;
      const refreshBeforeFail = refreshRequests;
      toggleBox()!.checked = true;
      const failedReenable = await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
      assert.equal(failedReenable.status, "blocked");
      assert.equal(refreshRequests, refreshBeforeFail);
      assert.ok(document.querySelector(`[data-mi-account-disable-error="${ACC_A}"]`));
      assert.equal(toggleBox()?.checked, false);

      app.settings.connectionMode = "demo";
      assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 })).status, "blocked");
      assert.equal(queueA.pausedScheduledCommands?.length, 1);
      app.settings.connectionMode = "xiaomiCloud";

      blockedKey = SCHEDULED_COMMANDS_STORAGE_KEY;
      await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
      assert.equal(
        resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)], hasExistingPreferences: true }).pendingRevalidationAccountIds.has(ACC_A),
        true,
      );

      blockedKey = AutomationRuleStore.storageKey;
      await refreshDevices(app, false);
      assert.equal(
        resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)], hasExistingPreferences: true }).pendingRevalidationAccountIds.has(ACC_A),
        true,
      );
      assert.equal(ruleStore.load()[0]?.isEnabled, false);

      blockedKey = null;
      await refreshDevices(app, false);
      assert.equal(
        resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)], hasExistingPreferences: true }).pendingRevalidationAccountIds.has(ACC_A),
        false,
      );
      assert.equal(app.scheduledCommands.some((t) => t.id === "t_atomic"), true);
      assert.equal(ruleStore.load()[0]?.isEnabled, true);
    } finally {
      Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: origSetItem });
    }

    queueA.scheduledCommands = [
      { id: "t_unknown_owner", command: "关未知设备", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "unknown-did-999", operation: { kind: "power", isOn: false } }], sourceScopes: [ACC_A, ACC_B] },
    ];
    app.scheduledCommandStore.persist();
    for (const [lang, expected] of [
      ["zh-Hans", /刷新|同步/],
      ["zh-Hant", /重新整理|同步/],
      ["en", /refresh/i],
    ] as const) {
      setLanguage(lang);
      const blocked = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
      assert.equal(blocked.status, "blocked");
      assert.match(app.replyBanner?.text ?? "", expected);
    }
    setLanguage("zh-Hans");
  });

  it("keeps Home Assistant and Demo devices, facets, and readings intact when disabling a Xiaomi account with dual-source off (4622786203)", async () => {
    const app = mountApp(async () => okMi({}));
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
      if (cmd === "ha_execute") haExecutes += 1;
      return (null as unknown) as T;
    });

    await refreshDevices(app, false);
    const haLight = app.devices.find((d) => d.name === "HA吸顶灯")!;
    assert.ok(haLight);
    const readingsBefore = app.environmentReadings.length;
    assert.ok(readingsBefore > 0);
    app.deviceFacets = {
      ...app.deviceFacets,
      [haLight.id]: [{
        id: "night", kind: "toggle", name: "night", title: "夜灯", serviceName: "switch",
        unit: null, scale: null, value: false, options: [], range: null,
        isWritable: true, writesByDefault: true, isHighValue: true,
        target: { kind: "property", entityId: "switch.ha_ceiling_night", piid: 1 },
      }],
    };

    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false)).status, "applied");
    assert.equal(app.devices.some((d) => d.id === haLight.id), true);
    assert.equal(app.environmentReadings.length, readingsBefore);
    assert.equal(app.deviceFacets[haLight.id]?.length, 1);
    const stateAfter = resolveMiAccountSelectionState({
      storage: localStorage, accounts: [makeMiAccount(SESS_A)],
      haBaseURL: app.settings.haBaseURL, haToken: app.settings.haToken,
      connectionMode: "homeAssistant", dualSourceEnabled: false, hasExistingPreferences: true,
    });
    assert.equal(stateAfter.knownDisabledDevices.some((d) => d.id === haLight.id), false);
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "light.ha_ceiling", isOn: false }), true);
    assert.equal(haExecutes, 1);

    await store.upsertAccount(SESS_B);
    app.settings.connectionMode = "demo";
    app.devices = [{
      id: "demo_desk_lamp",
      name: "演示台灯",
      roomId: "study",
      roomName: "书房",
      model: "demo.light",
      isOnline: true,
      kind: { kind: "light", entityId: "light.demo_desk", isOn: true, brightnessPercent: 80, colorTempKelvin: 4000, minKelvin: 2700, maxKelvin: 6500, availableEffects: [], currentEffect: null },
    }];
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_B, false)).status, "applied");
    assert.equal(app.devices.some((d) => d.id === "demo_desk_lamp"), true);
    const stateAfterDemo = resolveMiAccountSelectionState({
      storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)],
      connectionMode: "demo", dualSourceEnabled: false, hasExistingPreferences: true,
    });
    assert.equal(stateAfterDemo.knownDisabledDevices.some((d) => d.id === "demo_desk_lamp"), false);
  });

  it("queues revalidation when QR login re-enables a disabled account and releases paused items on sign-out across primary-switch, full sign-out, dual-source, and revoke-all flows (4622786217 / 4623897070)", async () => {
    let failRefresh = false;
    let executedCommands = 0;
    const writes: string[] = [];
    const transport = makeBasicMiTransport({
      name: "主号台灯",
      secName: "副号落地灯",
      writes,
      onBefore: () => {
        if (failRefresh) throw new Error("temporary network failure");
      },
    });

    const app = mountApp(transport);
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
    failRefresh = true;
    await addOrUpdateMiAccountOnHost(app, { ...SESS_A, serviceToken: "tok-a-rescanned" });
    const midState = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A)], hasExistingPreferences: true });
    assert.equal(midState.disabledAccountIds.has(ACC_A), false);
    assert.equal(midState.pendingRevalidationAccountIds.has(ACC_A), true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_auto")?.isEnabled, false);

    failRefresh = false;
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await refreshDevices(app, false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    processScheduledCommands(app, nowMs + 120_000);
    assert.equal(writes.length, 0);
    assert.deepEqual(app.scheduledCommands.map((t) => t.id), ["qr_future"]);
    assert.deepEqual(app.missedScheduledCommands.map((t) => t.id), ["qr_expired"]);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_auto")?.isEnabled, true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_qr_manual_off")?.isEnabled, false);

    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    const identityA = scheduledCommandIdentity(app.settings)!;
    const queueA = app.scheduledCommandStore.queue(identityA);
    queueA.scheduledCommands = [
      { id: "t_primary_future", command: "五分钟后关主号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t_primary_expired", command: "十秒后关主号灯", reply: "好", delaySeconds: 10, fireTimestampMs: nowMs - 5_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    queueA.missedScheduledCommands = [];
    app.scheduledCommandStore.persist();
    ruleStore.save([
      createAutomationRule({ id: "r_only_a", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "r_mixed_ab", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101", "202"], isOn: false } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    app.openSettingsSheet("connection");
    document.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${ACC_A}"]`)!.click();
    for (let i = 0; i < 40 && (store.getAccounts().some((a) => a.id === ACC_A) || (app.connDiagSession?.signingOutAccountIds.size ?? 0) > 0); i += 1) {
      await new Promise((r) => setTimeout(r, 0));
    }
    await new Promise((r) => setTimeout(r, 0));

    assert.notEqual(scheduledCommandIdentity(app.settings), identityA);
    assert.equal(queueA.pausedScheduledCommands?.length ?? 0, 0);
    assert.deepEqual(new Set(queueA.missedScheduledCommands.map((t) => t.id)), new Set(["t_primary_future", "t_primary_expired"]));
    assert.equal(ruleStore.load().find((r) => r.id === "r_only_a")?.pausedByCapabilities, undefined);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mixed_ab")?.isEnabled, false);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mixed_ab")?.pausedByCapabilities, undefined);

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    installSimpleHaLight(app);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const haQueue = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings)!);
    const miQueueB = app.scheduledCommandStore.queue(JSON.stringify(["xiaomiCloud", SESS_B.userId, "sg"]));
    const miOnlyDev = app.devices.find((d) => d.name === "副号落地灯")!;
    haQueue.scheduledCommands = [
      { id: "t_dual_ha_queue", command: "五分钟后关副号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: miOnlyDev.id, operation: { kind: "power", isOn: false } }], sourceScopes: ["ha:https://ha.example.test:8123", ACC_B] },
    ];
    miQueueB.scheduledCommands = [
      { id: "t_dual_mi_queue", command: "十分钟后关副号灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: miOnlyDev.id, operation: { kind: "power", isOn: false } }], sourceScopes: [ACC_B] },
    ];
    app.scheduledCommandStore.persist();
    ruleStore.save([
      createAutomationRule({ id: "r_qa_signout", isEnabled: true, trigger: "screenLocked", action: { kind: "quickAction", quickAction: "lightsOff" } }),
    ]);

    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true, nowMs });
    signOutXiaomiAccount(app);
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(haQueue.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(haQueue.missedScheduledCommands.some((t) => t.id === "t_dual_ha_queue"), true);
    assert.equal(miQueueB.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(miQueueB.missedScheduledCommands.some((t) => t.id === "t_dual_mi_queue"), true);

    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    setHostDualSourceEnabled(app, false, { persist: true });
    await store.upsertAccount(SESS_A);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    const miQueueC = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings)!);
    miQueueC.missedScheduledCommands = [];
    miQueueC.scheduledCommands = [
      { id: "t_revoke_all", command: "五分钟后关主号灯", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs });
    assert.equal(miQueueC.pausedScheduledCommands?.length, 1);

    await signOutAndRevokeAll(app);
    assert.equal(miQueueC.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(miQueueC.missedScheduledCommands.some((t) => t.id === "t_revoke_all"), true);
    assert.equal(executedCommands, 0);
    assert.equal(writes.length, 0);
  });

  it("tags, snapshots, and gates Xiaomi scenes across single-source, dual-source coordinator, and multi-account children (4622827966 / 4623897082 / 4624246983)", async () => {
    const cloudWrites: string[] = [];
    const app = mountApp(makeBasicMiTransport({ name: "客厅灯", writes: cloudWrites }));
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "leftover-ha-tok";
    setHostDualSourceEnabled(app, false, { persist: true });
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);
    await refreshDevices(app, false);

    app.scenes = [{ id: "mi_scene_night", name: "米家晚安", entityId: "101.2.a1" }];
    const ctxXiaomiOnly = buildHostCapabilityContext(app, [makeMiAccount(SESS_A)]);
    const indexedXiaomiOnly = buildIndexedCapabilityDevices(ctxXiaomiOnly);
    assert.equal(indexedXiaomiOnly.sceneRefs[0]?.connection, "xiaomi-cloud");
    assert.equal(indexedXiaomiOnly.sceneRefs[0]?.sourceScope, ACC_A);
    assert.equal(
      evaluateIntentsWriteGate({
        intents: [{ targetId: "mi_scene_night", operation: { kind: "activateScene" } }],
        context: ctxXiaomiOnly,
      }),
      null,
    );

    const miSceneId = `${ACC_A}/sc_mi_night`;
    app.scenes = [{ id: miSceneId, name: "米家晚安", entityId: "101.2.a1", accountId: ACC_A, sourceBackend: "xiaomiCloud" }];
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true })).status, "applied");
    assert.equal(app.scenes.length, 0);

    assert.equal(await app.applyCommand({ kind: "activateScene", entityId: "101.2.a1" }), false);
    assert.match(app.replyBanner?.text ?? "", /该米家账号已停用/);
    assert.equal(await app.applyCommand({ kind: "activateScene", entityId: miSceneId }), false);
    assert.match(
      evaluateIntentsWriteGate({
        intents: [{ targetId: miSceneId, operation: { kind: "activateScene" } }],
        context: buildHostCapabilityContext(app, [makeMiAccount(SESS_A)]),
      }) ?? "",
      /该米家账号已停用/,
    );

    const urlToasts: string[] = [];
    await onOpenURL(`menumijia://scene?name=${encodeURIComponent("米家晚安")}`, makeUrlHost(app, urlToasts));
    assert.match(urlToasts.at(-1) ?? "", /该米家账号已停用/);
    setLanguage("en");
    await onOpenURL(`menumijia://scene?name=${encodeURIComponent(miSceneId)}`, makeUrlHost(app, urlToasts));
    assert.match(urlToasts.at(-1) ?? "", /This Xiaomi account is turned off/);
    setLanguage("zh-Hans");
    await onOpenURL(`menumijia://scene?name=${encodeURIComponent("不存在的虚构场景")}`, makeUrlHost(app, urlToasts));
    assert.match(urlToasts.at(-1) ?? "", /不存在|尚未加载/);
    assert.deepEqual(cloudWrites, []);

    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, true)).status, "applied");
    const rawAfterReenable = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY) ?? "{}") as Record<string, unknown>;
    assert.equal(rawAfterReenable["knownDisabledScenes"], undefined);

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
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    assert.deepEqual(app.scenes.map((s) => s.id), ["scene.ha_movie"]);
    const multiState = app.multiAccountState!;
    const childA = multiState.children[ACC_A]!, childB = multiState.children[ACC_B]!;
    const miSceneFromLastMi: HomeScene = { id: "mi_scene_night", name: "米家晚安", entityId: "101.2.a1" };
    const miSceneFromChild: HomeScene = { id: "mi_scene_noon", name: "米家午休", entityId: "101.2.a2", accountId: ACC_A, sourceBackend: "xiaomiCloud" };
    const miSceneFromChildB: HomeScene = { id: "mi_scene_bedroom", name: "米家次卧", entityId: "202.2.a1", accountId: ACC_B, sourceBackend: "xiaomiCloud" };

    app.multiAccountState = {
      accounts: multiState.accounts,
      merged: { ...multiState.merged!, home: { ...multiState.merged!.home, scenes: [miSceneFromChild, miSceneFromChildB] } },
      children: {
        [ACC_A]: { ...childA, home: { ...childA.home, scenes: [miSceneFromChild] } },
        [ACC_B]: { ...childB, home: { ...childB.home, scenes: [miSceneFromChildB] } },
      },
    };
    const coordinator = app.dualSourceCoordinator!;
    await coordinator.refreshParallel({
      fetchHA: async () => coordinator.getLastHASnapshot()!,
      fetchMi: async () => ({
        home: { ...app.multiAccountState!.merged!.home, scenes: [miSceneFromLastMi] },
        homes: app.multiAccountState!.merged!.homes,
        accountStatuses: app.multiAccountState!.merged!.accountStatuses,
      }),
    });

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_ha_scene", isEnabled: true, trigger: "screenLocked", action: { kind: "scene", sceneId: "scene.ha_movie" } }),
      createAutomationRule({ id: "r_mi_dual_scene", isEnabled: true, trigger: "screenLocked", action: { kind: "scene", sceneId: miSceneFromChild.id } }),
    ]);

    const preflight = buildHostCapabilityContext(app, [makeMiAccount(SESS_A), makeMiAccount(SESS_B)]);
    assert.deepEqual(
      new Set(preflight.scenes.map((s) => s.id)),
      new Set(["scene.ha_movie", miSceneFromLastMi.id, miSceneFromChild.id, miSceneFromChildB.id]),
    );

    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false)).status, "requiresPauseConfirmation");
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true })).status, "applied");
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_dual_scene")?.isEnabled, false);
    assert.equal(ruleStore.load().find((r) => r.id === "r_ha_scene")?.isEnabled, true);

    const ctx = buildHostCapabilityContext(app, [makeMiAccount(SESS_A), makeMiAccount(SESS_B)]);
    assert.match(
      evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromLastMi.entityId, resolvedActiveDeviceId: null, context: ctx }) ?? "",
      /该米家账号已停用/,
    );
    assert.match(
      evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromChild.id, resolvedActiveDeviceId: null, context: ctx }) ?? "",
      /该米家账号已停用/,
    );
    const { indexedDevices, sceneRefs } = buildIndexedCapabilityDevices(ctx);
    const controlGate = evaluateControlTargetGate({ targetKind: "scene", targetId: miSceneFromChild.id, selection: ctx.state.selection, devices: indexedDevices, scenes: sceneRefs });
    assert.equal(controlGate.allowed, false);
    assert.equal(controlGate.rejectionReason?.code, "connectionScopeDisabled");
    assert.match(evaluateDisabledSceneUrlGate("米家晚安", app.settings) ?? "", /该米家账号已停用/);
    assert.match(evaluateDisabledSceneUrlGate(miSceneFromChild.id, app.settings) ?? "", /该米家账号已停用/);
    assert.equal(evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: "scene.ha_movie", resolvedActiveDeviceId: null, context: ctx }), null);
    assert.equal(evaluateDeviceEntityWriteGate({ targetKind: "scene", targetIdOrEntityId: miSceneFromChildB.id, resolvedActiveDeviceId: null, context: ctx }), null);
  });

  it("drops stale multi-account refresh on re-enable and supersedes in-flight sync so re-enabled devices and revalidation land immediately (4622827982)", async () => {
    let gateAccA = false;
    let releaseAccA!: () => void;
    const makeGate = () => new Promise<void>((r) => { releaseAccA = r; });
    let currentGate = makeGate();

    const app = mountApp(
      makeBasicMiTransport({
        name: "主号台灯",
        secName: "副号台灯",
        onBefore: async (user, path) => {
          if (gateAccA && user === "10001" && path.includes("device_list")) await currentGate;
        },
      }),
    );
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    const devBId = app.devices.find((d) => d.name === "副号台灯")!.id;

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_b_inflight", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: [devBId], isOn: false } }),
    ]);
    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true });
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), false);
    assert.equal(ruleStore.load()[0]?.isEnabled, false);

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
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), true);

    await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true });
    currentGate = makeGate();
    gateAccA = true;
    const inFlightBeforeToggle = refreshDevices(app, true);
    await new Promise((r) => setTimeout(r, 0));
    gateAccA = false;
    const reenablePromise = setMiAccountEnabledOnHost(app, ACC_B, true);
    releaseAccA();
    await Promise.all([inFlightBeforeToggle, reenablePromise]);
    assert.equal(app.devices.some((d) => d.name === "副号台灯"), true);
    assert.equal(ruleStore.load()[0]?.isEnabled, true);
  });

  it("preserves remaining disconnected Xiaomi accounts in DualSourceCoordinator.removeXiaomiAccount and distinguishes disconnected vs turned off in all 3 languages (4622827993)", async () => {
    let failAccBMode: "none" | "http" | "expired" = "none";
    const app = mountApp(
      makeBasicMiTransport({
        name: "主号台灯",
        secName: "副号独占台灯",
        onBefore: (user) => {
          if (user === "20002" && failAccBMode === "http") throw new MiCloudError("http", "米家网络暂时不可用", 503);
          if (user === "20002" && failAccBMode === "expired") throw new MiCloudError("sessionExpired", "米家登录已过期", 401);
        },
      }),
    );
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    installSimpleHaLight(app);
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);

    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true);

    failAccBMode = "http";
    await refreshDevices(app, false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true);

    await setMiAccountEnabledOnHost(app, ACC_A, false);
    assert.equal(app.devices.some((d) => d.name === "主号台灯"), false);
    assert.equal(app.devices.some((d) => d.name === "副号独占台灯"), true);
    const miStatusAfterDisableA = app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud;
    assert.equal(miStatusAfterDisableA?.kind, "disconnected");
    if (miStatusAfterDisableA?.kind === "disconnected") {
      assert.match(miStatusAfterDisableA.reason, /网络暂时不可用/);
      assert.doesNotMatch(miStatusAfterDisableA.reason, /停用|turned off/i);
    }

    failAccBMode = "expired";
    await setMiAccountEnabledOnHost(app, ACC_A, true);
    await setMiAccountEnabledOnHost(app, ACC_A, false);
    const miStatusExpiredB = app.dualSourceCoordinator?.getSourceStatuses().xiaomiCloud;
    assert.equal(miStatusExpiredB?.kind, "disconnected");
    if (miStatusExpiredB?.kind === "disconnected") {
      assert.match(miStatusExpiredB.reason, /过期/);
      assert.doesNotMatch(miStatusExpiredB.reason, /停用|turned off/i);
    }

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

  it("keeps shared Xiaomi device references active when another enabled Xiaomi account still owns the device and preserves multi-account room/home ID namespacing (4623357855 / 4623357863)", async () => {
    const executedByUser: string[] = [];
    let light101On = true;
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      if (path === "miotspec/prop/set") {
        executedByUser.push(user);
        light101On = false;
        return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
      }
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return user === "10001"
          ? okMi({ homelist: [{ id: "9101", name: "主家", roomlist: [{ id: "r-main", name: "主卧", dids: ["101", "102"] }] }] })
          : okMi({ homelist: [{ id: "9202", name: "副家", roomlist: [{ id: "r-sec", name: "次卧", dids: ["101", "202"] }] }] });
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
              list: [
                { did: "101", name: "共享吸顶灯", model: LIGHT_MODEL, isOnline: true },
                { did: "202", name: "次卧台灯", model: LIGHT_MODEL, isOnline: true },
              ],
            });
      }
      if (path === "miotspec/prop/get") {
        return okMi([
          { did: "101", siid: 2, piid: 1, code: 0, value: light101On },
          { did: "101", siid: 2, piid: 2, code: 0, value: 80 },
          { did: "102", siid: 2, piid: 1, code: 0, value: true },
          { did: "202", siid: 2, piid: 1, code: 0, value: true },
          { did: "202", siid: 2, piid: 2, code: 0, value: 75 },
        ]);
      }
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);

    const scopedRoomB = `${ACC_B}/room_r-sec`;
    const scopedHomeB = `${ACC_B}/9202`;
    assert.equal(app.devices.find((d) => d.id === "202")?.roomId, scopedRoomB);
    assert.equal(app.homes.some((h) => h.id === scopedHomeB), true);
    app.settings.layout.roomAliases = { [scopedRoomB]: "温馨次卧" };
    app.settings.layout.roomOrder = [scopedRoomB, `${ACC_A}/room_r-main`];
    app.selectRoom(scopedRoomB, "温馨次卧");

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

    const disableA = await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs });
    assert.equal(disableA.status, "applied");
    assert.equal(app.scheduledCommands.some((t) => t.id === "t_shared_101"), true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_shared_101")?.isEnabled, true);
    const stateAfterA = resolveMiAccountSelectionState({ storage: localStorage, accounts: [makeMiAccount(SESS_A), makeMiAccount(SESS_B)], hasExistingPreferences: true });
    assert.equal(stateAfterA.pausedQuickActionIds.has("lightsOff"), false);
    assert.equal(stateAfterA.knownDisabledDevices.some((d) => d.id === "101"), false);
    assert.equal(app.devices.some((d) => d.id === "101"), true);
    assert.equal(app.devices.some((d) => d.id === "102"), false);

    const sharedLightEntityId = (app.devices.find((d) => d.id === "101")!.kind as { entityId: string }).entityId;
    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: sharedLightEntityId, isOn: false }), true);
    assert.deepEqual(executedByUser, ["20002"]);

    await refreshDevices(app, false);
    const devBAfter = app.devices.find((d) => d.id === "202")!;
    assert.equal(devBAfter.roomId, scopedRoomB);
    assert.equal(app.homes.some((h) => h.id === scopedHomeB), true);
    const cutDevices = filterByListCut(app.devices, app.listCut, false, { layout: app.layout });
    assert.equal(cutDevices[0]?.roomName, "温馨次卧");
    assert.equal(orderAndAliasRooms([{ id: devBAfter.roomId, name: devBAfter.roomName }], app.layout)[0]?.name, "温馨次卧");

    assert.equal((await setMiAccountEnabledOnHost(app, ACC_B, false, { nowMs })).status, "requiresPauseConfirmation");
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_B, false, { confirmPause: true, nowMs })).status, "applied");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "r_shared_101")?.isEnabled, false);

    await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 5_000 });
    await setMiAccountEnabledOnHost(app, ACC_B, true, { nowMs: nowMs + 5_000 });
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, true, { persist: true });
    installSimpleHaLight(app);
    await refreshDevices(app, false);
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false, { nowMs: nowMs + 10_000 })).status, "applied");
    assert.equal(app.devices.some((d) => d.id === "101"), true);
    assert.equal(app.devices.find((d) => d.id === "202")?.roomId, scopedRoomB);
    assert.equal(app.scheduledCommands.some((t) => t.id === "t_shared_101"), true);
  });

  it("does not prematurely expire Xiaomi timers or unpause lightsOff on Home Assistant refresh while Xiaomi revalidation is pending (4623387411)", async () => {
    const writes: string[] = [];
    const sceneId = `${ACC_A}/mi-scene:9101:sc_night`;
    const baseTransport = makeBasicMiTransport({ name: "米家书房灯", writes });
    const app = mountApp(async (req) => {
      // A real cloud scene row survives every Xiaomi round because the round fetches it. The
      // scene API needs the home's owner uid, which the basic transport's home listing omits.
      const path = reqPath(req);
      if (path === "v2/homeroom/gethome_merged") {
        return okMi({ homelist: [{ id: "9101", uid: "10001", name: "Home-A", roomlist: [] }] });
      }
      if (path.includes("GetSimpleSceneList")) {
        return okMi({ manual_scene_info_list: [{ scene_id: "sc_night", scene_name: "米家晚安" }] });
      }
      return baseTransport(req);
    });
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);
    await refreshDevices(app, false);
    assert.ok(app.scenes.some((scene) => scene.id === sceneId), "the refresh owns the cloud scene row");
    markTimerSnapshotReady(app);

    const nowMs = Date.now();
    const miQueue = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    miQueue.scheduledCommands = [
      { id: "t_mi_valid_future", command: "十分钟后关书房灯", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
      { id: "t_mi_valid_scene", command: "十分钟后执行晚安场景", reply: "好", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, intents: [{ targetId: sceneId, operation: { kind: "activateScene" } }] },
      { id: "t_mi_expired", command: "一分钟后关书房灯", reply: "好", delaySeconds: 60, fireTimestampMs: nowMs + 60_000, intents: [{ targetId: "101", operation: { kind: "power", isOn: false } }] },
    ];
    app.scheduledCommandStore.persist();
    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_mi_pending_dev", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: ["101"], isOn: false } }),
      createAutomationRule({ id: "r_mi_pending_qa", isEnabled: true, trigger: "screenLocked", action: { kind: "quickAction", quickAction: "lightsOff" } }),
    ]);

    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true, nowMs })).status, "applied");
    assert.equal(miQueue.pausedScheduledCommands?.length, 3);

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-tok";
    setHostDualSourceEnabled(app, false, { persist: true });
    installSimpleHaLight(app);

    const haQueue = app.scheduledCommandStore.queue(scheduledCommandIdentity(app.settings));
    haQueue.pausedScheduledCommands = [{
      command: { id: "t_dual_mi_scene", command: "五分钟后米家晚安", reply: "好", delaySeconds: 300, fireTimestampMs: nowMs + 300_000, intents: [{ targetId: sceneId, operation: { kind: "activateScene" } }], sourceScopes: ["ha:https://ha.example.test:8123", ACC_A] },
      originalPartition: "waiting",
      sourceScopes: ["ha:https://ha.example.test:8123", ACC_A],
      pausedCapabilities: ["xiaomi-cloud"],
    }];
    app.scheduledCommandStore.persist();

    await refreshDevices(app, false);
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, true, { nowMs: nowMs + 20_000 })).status, "applied");
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
    assert.equal(stateInHa.pendingRevalidationAccountIds.has(ACC_A), true);
    assert.equal(stateInHa.pausedQuickActionIds.has("lightsOff"), true);
    assert.equal(miQueue.pausedScheduledCommands?.length, 3);
    assert.equal(miQueue.missedScheduledCommands.length, 0);
    assert.equal(haQueue.pausedScheduledCommands?.length, 1);
    assert.equal(haQueue.missedScheduledCommands.length, 0);

    app.settings.connectionMode = "xiaomiCloud";
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await refreshDevices(app, false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    // A Xiaomi round owns its cloud scene rows, and the transport refetches the scene, so the
    // scheduled target survives the reenable refresh without a manual fixture.
    processScheduledCommands(app, nowMs + 120_000);
    assert.equal(writes.length, 0);
    assert.deepEqual(new Set(miQueue.scheduledCommands.map((t) => t.id)), new Set(["t_mi_valid_future", "t_mi_valid_scene"]));
    assert.deepEqual(miQueue.missedScheduledCommands.map((t) => t.id), ["t_mi_expired"]);
    assert.equal(miQueue.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_dev")?.isEnabled, true);
    assert.equal(ruleStore.load().find((r) => r.id === "r_mi_pending_qa")?.isEnabled, true);
  });
});

describe("P3a-W retained alert-signal cleanup, pins and per-account index entries", () => {
  const retainedSensor = (id: string, accountId: string, name: string): SmartDevice => ({
    id,
    name,
    roomId: "r1",
    roomName: "客厅",
    model: MOISTURE_MODEL,
    isOnline: true,
    accountId,
    kind: { kind: "sensor", temperature: null, humidity: null, battery: 80, statusText: "normal" },
  });
  const hiddenCard = (id: string, accountId: string): CapabilityIndexedDevice => ({
    id,
    name: `card-${id}`,
    category: "cover",
    connection: "xiaomi-cloud",
    sourceScope: miAccountScope(accountId),
    isSourceAvailable: true,
    upstreamHiddenOrDisabled: false,
    participatesInAllOff: false,
    safetySignals: [],
    readKeys: [],
    safetyReadKeys: [],
  });
  const waitFor = async (predicate: () => boolean): Promise<void> => {
    for (let i = 0; i < 400; i += 1) {
      if (predicate()) return;
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
    assert.fail("timed out waiting for sign-out to settle");
  };

  it("drops one account's retained signals and hidden index entries while keeping sibling entries and disambiguating shared raw dids", async () => {
    const host = { safetyRetainedDevices: [], safetyRetainedDeviceFacets: {}, hiddenMiDevices: [] } as unknown as {
      safetyRetainedDevices: SmartDevice[];
      safetyRetainedDeviceFacets: Readonly<Record<string, readonly FacetControl[]>>;
      hiddenMiDevices: readonly CapabilityIndexedDevice[];
    };
    applyMiotTypePruneSnapshot(host, {
      safetyDevices: [retainedSensor("101", ACC_A, "主号漏水"), retainedSensor("202", ACC_B, "副号漏水")],
      safetyDeviceFacets: { "101": [], "202": [] },
      hiddenDevices: [hiddenCard("101", ACC_A), hiddenCard("202", ACC_B)],
    });
    dropMiotTypePruneSnapshotForAccount(host, ACC_A);
    assert.deepEqual(host.safetyRetainedDevices.map((d) => d.id), ["202"]);
    assert.deepEqual(Object.keys(host.safetyRetainedDeviceFacets), ["202"]);
    assert.deepEqual(host.hiddenMiDevices.map((d) => d.id), ["202"]);
    applyMiotTypePruneSnapshot(host, null);
    assert.deepEqual(host.safetyRetainedDevices, []);
    assert.deepEqual(host.hiddenMiDevices, []);

    const coordinator = new DualSourceCoordinator(null);
    await coordinator.refreshParallel({
      fetchHA: async () => null,
      fetchMi: async () => ({
        home: { rooms: [], devices: [retainedSensor("101", ACC_A, "主号台灯"), retainedSensor("202", ACC_B, "副号台灯")], environmentReadings: [], scenes: [] },
        safetyDevices: [retainedSensor("s101", ACC_A, "主号漏水"), retainedSensor("s202", ACC_B, "副号漏水")],
        safetyDeviceFacets: { s101: [], s202: [] },
        hiddenDevices: [hiddenCard("101", ACC_A), hiddenCard("202", ACC_B)],
        accountStatuses: { [ACC_A]: { kind: "connected" }, [ACC_B]: { kind: "connected" } },
      }),
    });
    coordinator.removeXiaomiAccount(ACC_A, "zh-Hans", { remainingEnabledCount: 1, reason: "signedOut" });
    const snapshot = coordinator.getLastMiSnapshot()!;
    assert.deepEqual(snapshot.safetyDevices?.map((d) => d.id), ["s202"]);
    assert.deepEqual(Object.keys(snapshot.safetyDeviceFacets ?? {}), ["s202"]);
    assert.deepEqual(snapshot.hiddenDevices?.map((d) => d.id), ["202"]);

    const accountA = makeMiAccount(SESS_A);
    const accountB = makeMiAccount(SESS_B);
    const emptySnap = (acc: ReturnType<typeof makeMiAccount>) => ({
      account: acc,
      home: { rooms: [], devices: [], environmentReadings: [], scenes: [] },
      homes: [], rawDevices: [], allDevices: [], allRooms: [], specs: {},
      lightGroupOwners: new Map(),
      hiddenDevices: [hiddenCard("101", acc.id)],
      status: { kind: "connected" as const },
      tokenStatus: { kind: "valid" as const },
    });
    const merged = mergeMiAccountSnapshots([accountA, accountB], {
      [accountA.id]: emptySnap(accountA),
      [accountB.id]: emptySnap(accountB),
    });
    assert.deepEqual(
      (merged.hiddenDevices ?? []).map((d) => `${d.sourceScope}|${d.id}`).sort(),
      [`${miAccountScope(accountA.id)}|101`, `${miAccountScope(accountB.id)}|101`],
    );

    const entries = [hiddenCard("101", ACC_A), hiddenCard("101", ACC_B)];
    assert.equal(resolveHiddenTypeDeviceByEntity(`${ACC_A}/101`, entries)?.sourceScope, miAccountScope(ACC_A));
    assert.equal(resolveHiddenTypeDeviceByEntity(`${ACC_B}/101`, entries)?.sourceScope, miAccountScope(ACC_B));
    assert.equal(resolveHiddenTypeDeviceByEntity("101", entries)?.sourceScope, miAccountScope(ACC_A));
  });

  it("clears retained signals on disable/sign-out, stops planning a disabled account on next refresh, and recomputes safety signals after 安全与提醒 changes", async () => {
    const requests: Array<{ user: string; path: string }> = [];
    const transport: HttpTransport = async (req) => {
      const user = reqUser(req), path = reqPath(req);
      requests.push({ user, path });
      if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
        return okMi({ homelist: [{ id: user === "10001" ? "9101" : "9202", name: "Home", roomlist: [] }] });
      }
      if (path === "v2/home/device_list_page" || path === "home/device_list") {
        return okMi({
          list: user === "10001"
            ? [{ did: "101", name: "主号台灯", model: LIGHT_MODEL, isOnline: true }]
            : [
                { did: "202", name: "副号台灯", model: LIGHT_MODEL, isOnline: true },
                { did: "203", name: "副号漏水", model: MOISTURE_MODEL, isOnline: true },
              ],
        });
      }
      if (path === "miotspec/prop/get") {
        return okMi([{ did: "203", siid: 2, piid: 1001, code: 0, value: false }]);
      }
      return okMi({});
    };

    const app = mountApp(transport);
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = SESS_A;
    const store = getHostMiAccountsStore(app);
    await store.upsertAccount(SESS_A);
    await store.upsertAccount(SESS_B);
    await refreshDevices(app, false);
    assert.deepEqual(app.devices.map((d) => d.id).sort(), ["101", "202", "203"]);

    applyMiotTypePruneSnapshot(app, {
      safetyDevices: [retainedSensor("s101", ACC_A, "主号漏水"), retainedSensor("s202", ACC_B, "副号漏水")],
      safetyDeviceFacets: { s101: [], s202: [] },
      hiddenDevices: [hiddenCard("101", ACC_A), hiddenCard("202", ACC_B)],
    });
    assert.equal((await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true })).status, "applied");
    assert.deepEqual(app.safetyRetainedDevices?.map((d) => d.id), ["s202"]);
    assert.deepEqual(app.hiddenMiDevices.map((d) => d.id), ["202"]);

    requests.length = 0;
    await refreshDevices(app, false);
    assert.deepEqual([...new Set(requests.map((r) => r.user))], ["20002"]);
    assert.ok(requests.some((r) => r.path === "miotspec/prop/get" && r.user === "20002"));
    assert.equal((app.safetyRetainedDevices ?? []).some((d) => d.id === "s101"), false);
    assert.equal(app.hiddenMiDevices.some((d) => d.id === "101"), false);

    applyMiotTypePruneSnapshot(app, {
      safetyDevices: [retainedSensor("s101", ACC_A, "主号漏水"), retainedSensor("s202", ACC_B, "副号漏水")],
      safetyDeviceFacets: { s101: [], s202: [] },
      hiddenDevices: [hiddenCard("101", ACC_A), hiddenCard("202", ACC_B)],
    });
    app.settings.haBaseURL = "https://ha.example.test:8123";
    app.settings.haToken = "ha-token";
    setHostDualSourceEnabled(app, true);
    const coordinator = getHostDualSourceCoordinator(app);
    await coordinator.refreshParallel({
      fetchHA: async () => null,
      fetchMi: async () => ({
        home: { rooms: [], devices: [retainedSensor("101", ACC_A, "主号台灯"), retainedSensor("202", ACC_B, "副号台灯")], environmentReadings: [], scenes: [] },
        safetyDevices: [retainedSensor("s101", ACC_A, "主号漏水"), retainedSensor("s202", ACC_B, "副号漏水")],
        safetyDeviceFacets: { s101: [], s202: [] },
        hiddenDevices: [hiddenCard("101", ACC_A), hiddenCard("202", ACC_B)],
        accountStatuses: { [ACC_A]: { kind: "connected" }, [ACC_B]: { kind: "connected" } },
      }),
    });
    app.refreshDevices = async () => {};
    app.openSettingsSheet("connection");
    document.querySelector<HTMLButtonElement>(`[data-mi-account-signout="${ACC_A}"]`)!.click();
    await waitFor(() => !document.querySelector(`[data-mi-account-card="${ACC_A}"]`));
    assert.deepEqual(app.safetyRetainedDevices?.map((d) => d.id), ["s202"]);
    assert.deepEqual(Object.keys(app.safetyRetainedDeviceFacets ?? {}), ["s202"]);
    assert.deepEqual(app.hiddenMiDevices.map((d) => d.id), ["202"]);

    app.layout.pinnedDeviceIds = [`${ACC_A}/lamp`, "101"];
    const defaults = hostMiotTypePruneOptions(app);
    for (const kind of ["leak", "smoke", "gas", "lock", "lowBattery", "longRunningPlug", "longRunningClimate", "highPower", "starredOffline"] as const) {
      assert.ok(defaults.safetySignals.includes(kind));
    }
    assert.deepEqual(defaults.starredDeviceIds, [`${ACC_A}/lamp`, "101"]);

    saveSafetyGuardPrefs({
      enableSafetyAlerts: false, longRunningPlug: false, longRunningClimate: false, lowBattery: false, favoriteOffline: false,
    }, localStorage);
    assert.deepEqual(hostMiotTypePruneOptions(app).safetySignals, ["leak", "smoke", "gas", "lock"]);

    saveSensorAlertPolicy({ enabled: { leak: false, smoke: false, gas: false, lock: false }, onlyWhenAway: false }, localStorage);
    assert.deepEqual(hostMiotTypePruneOptions(app).safetySignals, []);
    assert.deepEqual(hostMiotTypePruneOptions(app).starredDeviceIds, [`${ACC_A}/lamp`, "101"]);
  });
});
