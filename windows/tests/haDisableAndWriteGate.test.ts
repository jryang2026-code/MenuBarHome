import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import "./dom.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { createTransport } from "../src/ui/transport.js";
import {
  buildHostCapabilityContext,
  getHostHaLifecyclePhase,
  getHostMiAccountsStore,
  haCacheIfEnabled,
  isHostHaEnabled,
  refreshDevices,
  setHostDeviceSourcePin,
  setHostDualSourceEnabled,
  setHostHAInvokeOverride,
  settingsHaCacheIfEnabled,
} from "../src/ui/cloudRefresh.js";
import {
  disconnectHomeAssistantOnHost,
  runUnsupportedDevicesScanOnHost,
  setHaConnectionEnabledOnHost,
  setMiAccountEnabledOnHost,
} from "../src/ui/connectionsAndDiagView.js";
import { resolveConnectionStatus } from "../src/ui/connectionStatus.js";
import {
  confirmMissedScheduledCommand,
  enqueueScheduledCommand,
  markTimerSnapshotReady,
  processScheduledCommands,
  scheduledCommandIdentity,
  scheduledCommandsReady,
} from "../src/ui/scheduledCommands.js";
import {
  enqueueIncomingOpenUrl,
  executeBuiltInQuickAction,
  getActiveRaycastBridgeTokenForHost,
  hasPendingUrlConfirmation,
  setRaycastIntegrationEnabled,
} from "../src/ui/speechGuard.js";
import { DEVICE_CATEGORY_IDS } from "../src/core/capabilityManifest.js";
import { onOpenURL, type AppURLCommandHost } from "../src/core/appUrlCommand.js";
import { AutomationRuleStore, createAutomationRule, executeAutomationRule } from "../src/core/automationEngine.js";
import {
  dispatchSystemContextEvent,
  executeAutomationCardUndo,
  getHostActivityCenter,
  tickSafetyHealthAndAutomation,
} from "../src/ui/activityStackView.js";
import { controlFailureUserMessage } from "../src/core/controlFailure.js";
import {
  HaBlockedRequestError,
  acquireHaTransportLease,
  beginHaScopeDisable,
  getHaScopeInFlightCount,
  getHaScopeLifecyclePhase,
  isHaBlockedRequestError,
  isHaDrainTimerRefedForTests,
  isHaNativeCancelReady,
  isHaScopeStopTimedOut,
  requestHaScopeEnableAfterDrain,
  resetHaTransportGateForTests,
  setHaNativeCancelReadyForTests,
  setHaStopDrainTimeoutMsForTests,
} from "../src/core/haTransportGate.js";
import { HomeAssistantClient, homeAssistantIdentity } from "../src/core/homeAssistant.js";
import { HomeAssistantProvider } from "../src/core/homeProvider.js";
import { setLanguage } from "../src/core/i18n.js";
import { makeMiAccount } from "../src/core/miAccountsStore.js";
import {
  MI_ACCOUNT_CAPABILITY_STORAGE_KEY,
  haConnectionScope,
  previewHaConnectionDisable,
  resolveMiAccountSelectionState,
  writeMiAccountSelectionMutation,
} from "../src/core/miAccountControl.js";
import {
  MiotSpecResolver,
  parseMiotDeviceSpec,
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  type MiSession,
} from "../src/core/miCloudClient.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY } from "../src/core/scheduledCommands.js";
import { CredentialVault, type SecureInvoke } from "../src/core/secureStore.js";
import { fetchHomeAssistantSensorHistory } from "../src/core/sensorHistory.js";
import { syncSensorHistoryHost } from "../src/ui/sensorHistoryView.js";
import { devicePrimaryEntityId, type SmartDevice } from "../src/core/models.js";

const SEC = "AQIDBAUGBwgJCgsMDQ4PEA==";
const SESS_A: MiSession = { userId: "10001", cUserId: "c1", ssecurity: SEC, serviceToken: "tok-a", passToken: "", region: "cn" };
const ACC_A = makeMiAccount(SESS_A).id;
const HA_URL = "https://ha.example.test:8123";
const HA_SCOPE = "ha:https://ha.example.test:8123";
const LIGHT_MODEL = "yeelink.light.lamp4";
const PLUG_MODEL = "chuangmi.plug.v3";
const CAM_MODEL = "isa.camera.hlc7";

const LIGHT_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:light:0000A001:yeelink-lamp4:1",
  services: [{
    iid: 2,
    type: "urn:miot-spec-v2:service:light:00007802:yeelink-lamp4:1",
    properties: [
      { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-lamp4:1", format: "bool", access: ["read", "write"] },
      { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-lamp4:1", format: "uint8", access: ["read", "write"], valueRange: [1, 100, 1] },
    ],
    actions: [],
  }],
})!;
const PLUG_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:outlet:0000A002:chuangmi-v3:1",
  services: [{
    iid: 2,
    type: "urn:miot-spec-v2:service:switch:0000780C:chuangmi-v3:1",
    properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:chuangmi-v3:1", format: "bool", access: ["read", "write"] }],
    actions: [],
  }],
})!;
const CAM_SPEC = parseMiotDeviceSpec({
  type: "urn:miot-spec-v2:device:camera:0000A01C:isa-hlc7:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:camera-control:0000782F:isa-hlc7:1",
      properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:isa-hlc7:1", format: "bool", access: ["read", "write"] }],
      actions: [],
    },
    {
      iid: 9,
      type: "urn:miot-spec-v2:service:p2p-stream:00007881:isa-hlc7:1",
      properties: [],
      actions: [
        { iid: 1, type: "urn:miot-spec-v2:action:start-p2p-stream:00002839:isa-hlc7:1" },
        { iid: 2, type: "urn:miot-spec-v2:action:stop-stream:00002822:isa-hlc7:1" },
      ],
    },
  ],
})!;

interface Deferred<T> {
  readonly promise: Promise<T>;
  resolve(value: T): void;
  reject(reason?: unknown): void;
}

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const okMi = (result: unknown): HttpResponse => ({
  status: 200,
  headers: {},
  body: JSON.stringify({ code: 0, message: "ok", result }),
});
const reqPath = (req: HttpRequest): string => new URL(req.url).pathname.replace(/^\/(?:app\/)?/, "");

function makeHaSnapshotPayload(overrides: Partial<Record<string, unknown>> = {}): Record<string, unknown> {
  return {
    areas: [{ area_id: "living", name: "客厅" }],
    devices: [
      { id: "ha-dev-strip", name: "HA灯带", area_id: "living" },
      { id: "ha-dev-heater", name: "HA取暖器插座", area_id: "living" },
      { id: "ha-dev-sensor", name: "HA温湿度计", area_id: "living" },
      { id: "ha-dev-cam", name: "HA门廊摄像机", area_id: "living" },
    ],
    entities: [
      { entity_id: "light.ha_strip", device_id: "ha-dev-strip" },
      { entity_id: "switch.ha_heater", device_id: "ha-dev-heater" },
      { entity_id: "sensor.ha_temp", device_id: "ha-dev-sensor" },
      { entity_id: "camera.ha_porch", device_id: "ha-dev-cam" },
    ],
    states: [
      { entity_id: "light.ha_strip", state: "on", attributes: { friendly_name: "HA灯带", brightness: 204, supported_color_modes: ["brightness"] } },
      { entity_id: "switch.ha_heater", state: "off", attributes: { friendly_name: "HA取暖器插座", device_class: "outlet" } },
      { entity_id: "sensor.ha_temp", state: "24.5", attributes: { friendly_name: "HA温湿度计", device_class: "temperature", unit_of_measurement: "°C" } },
      { entity_id: "camera.ha_porch", state: "streaming", attributes: { friendly_name: "HA门廊摄像机", entity_picture: "/api/camera_proxy/camera.ha_porch" } },
      { entity_id: "scene.ha_movie", state: "scenic", attributes: { friendly_name: "HA影院模式" } },
    ],
    ...overrides,
  };
}

function makeHarness(options: {
  onHaSetConnection?: (args: Record<string, unknown>) => Promise<void>;
  onHaSnapshot?: (args: Record<string, unknown>) => Promise<Record<string, unknown>>;
  onHaExecute?: (args: Record<string, unknown>) => Promise<unknown>;
  onTransport?: (req: HttpRequest) => Promise<HttpResponse>;
  workstationLocked?: boolean;
} = {}) {
  const vaultData = new Map<string, string>();
  const tauriCalls: Array<{ cmd: string; args: Record<string, unknown> }> = [];
  const miWritePaths: string[] = [];
  const aiRequests: string[] = [];
  let lockChecks = 0;

  const invoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> => {
    tauriCalls.push({ cmd, args });
    const name = String(args["name"] ?? "");
    if (cmd === "secure_store_get") return ((vaultData.get(name) ?? null) as unknown) as T;
    if (cmd === "secure_store_set") {
      vaultData.set(name, String(args["value"] ?? ""));
      return (null as unknown) as T;
    }
    if (cmd === "secure_store_delete") {
      vaultData.delete(name);
      return (null as unknown) as T;
    }
    if (cmd === "secure_store_list_mi_account_slots") {
      return [...vaultData.keys()].filter((k) => k.startsWith("mi_session_")).map((k) => k.slice("mi_session_".length)) as unknown as T;
    }
    if (cmd === "is_workstation_locked") {
      lockChecks += 1;
      return (Boolean(options.workstationLocked) as unknown) as T;
    }
    if (cmd === "ha_set_connection") return (await options.onHaSetConnection?.(args)) as T;
    if (cmd === "ha_snapshot") return ((options.onHaSnapshot ? await options.onHaSnapshot(args) : makeHaSnapshotPayload()) as unknown) as T;
    if (cmd === "ha_execute") return ((options.onHaExecute ? await options.onHaExecute(args) : { ok: true }) as unknown) as T;
    if (cmd === "resolve_ha_camera_stream") return ({ mode: "mjpeg", streamUrl: `${HA_URL}/api/camera_proxy_stream/camera.ha_porch` } as unknown) as T;
    if (cmd === "fetch_ha_camera_frame") return ("data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/" as unknown) as T;
    return (null as unknown) as T;
  };

  const defaultTransport: HttpTransport = async (req) => {
    if (req.url.includes("openai") || req.url.includes("assistant") || req.url.includes("chat/completions")) {
      aiRequests.push(req.url);
      return { status: 500, headers: {}, body: "unexpected AI call" };
    }
    if (options.onTransport) return options.onTransport(req);
    const path = reqPath(req);
    if (path === "miotspec/prop/set" || path === "miotspec/action" || path.includes("scene/start")) {
      miWritePaths.push(path);
      return okMi([{ did: "101", siid: 2, piid: 1, code: 0 }]);
    }
    if (path === "v2/homeroom/gethome_merged" || path === "v2/homeroom/gethome") {
      return okMi({ homelist: [{ id: "9101", name: "我的家", roomlist: [{ id: "r1", name: "客厅", dids: ["101", "102", "103"] }] }] });
    }
    if (path === "v2/home/device_list_page" || path === "home/device_list") {
      return okMi({
        list: [
          { did: "101", name: "吸顶主灯", model: LIGHT_MODEL, isOnline: true, mac: "AA:BB:CC:DD:EE:01" },
          { did: "102", name: "米家台灯", model: LIGHT_MODEL, isOnline: true, mac: "AA:BB:CC:DD:EE:02" },
          { did: "103", name: "客厅摄像机", model: CAM_MODEL, isOnline: true, localip: "192.168.1.66" },
        ],
      });
    }
    if (path === "miotspec/prop/get") {
      return okMi([
        { did: "101", siid: 2, piid: 1, code: 0, value: true },
        { did: "101", siid: 2, piid: 2, code: 0, value: 80 },
        { did: "102", siid: 2, piid: 1, code: 0, value: true },
        { did: "102", siid: 2, piid: 2, code: 0, value: 60 },
        { did: "103", siid: 2, piid: 1, code: 0, value: true },
      ]);
    }
    return okMi({});
  };

  (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = { invoke };
  const app = new MenuMijiaWindowsApp(document.getElementById("app")!);
  (app as unknown as { transport: HttpTransport }).transport = defaultTransport;
  (app as unknown as { specResolver: MiotSpecResolver }).specResolver = new MiotSpecResolver(defaultTransport, {
    [LIGHT_MODEL]: LIGHT_SPEC,
    [PLUG_MODEL]: PLUG_SPEC,
    [CAM_MODEL]: CAM_SPEC,
  });
  const secureInvoke: SecureInvoke = <T>(cmd: string, args?: Record<string, unknown>) => invoke<T | null>(cmd, args);
  (app as unknown as { credentialVault: CredentialVault }).credentialVault = new CredentialVault(secureInvoke);
  setHostHAInvokeOverride(app, invoke);
  app.miAccountsStore = null;
  app.settings.hasCompletedOnboarding = true;
  app.activeSheet = "none";
  app.timerCredentialsReady = true;

  const countCmd = (cmd: string): number => tauriCalls.filter((c) => c.cmd === cmd).length;
  return {
    app,
    vaultData,
    tauriCalls,
    miWritePaths,
    aiRequests,
    get lockChecks() {
      return lockChecks;
    },
    invoke,
    countCmd,
  };
}

let dom: Window | null = null;
let removeCssEscape: (() => void) | null = null;

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  removeCssEscape = installCssEscape();
  setLanguage("zh-Hans");
  setHaNativeCancelReadyForTests(true);
});

afterEach(async () => {
  resetHaTransportGateForTests();
  removeCssEscape?.();
  if (dom) await closeTestWindow(dom);
  dom = null;
});

describe("P2b-W Home Assistant disable, draining lifecycle & unified host write gate", () => {
  it("preserves capabilitySelection.v1 schema/extraFields, keeps HA scope across token rotation, and cleans up on disconnect", async () => {
    const h = makeHarness();
    const { app, vaultData } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = `${HA_URL}/api/websocket`;
    app.settings.haToken = "ha-tok-1";
    vaultData.set("ha_token", "ha-tok-1");

    await app.refreshHADevices(false);
    assert.equal(app.devices.some((d) => d.name === "HA灯带"), true);
    assert.equal(app.scenes.some((s) => s.name === "HA影院模式"), true);

    const initialState = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [],
      haBaseURL: app.settings.haBaseURL,
      haToken: app.settings.haToken,
      connectionMode: "homeAssistant",
      hasExistingPreferences: true,
    });
    initialState.persistIfMigrationReady();
    const seededRaw = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY)!) as Record<string, unknown>;
    seededRaw["futureCapabilityField"] = { keep: 42 };
    localStorage.setItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY, JSON.stringify(seededRaw));

    const stripId = app.devices.find((d) => d.name === "HA灯带")!.id;
    const nowMs = 1_760_000_000_000;
    const identity = scheduledCommandIdentity(app.settings)!;
    markTimerSnapshotReady(app);
    const queue = app.scheduledCommandStore.queue(identity);
    queue.scheduledCommands = [{
      id: "t_ha_1",
      command: "五分钟后关HA灯带",
      reply: "好",
      delaySeconds: 300,
      fireTimestampMs: nowMs + 300_000,
      intents: [{ targetId: stripId, operation: { kind: "power", isOn: false } }],
    }];
    app.scheduledCommandStore.persist();

    const dis = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true, nowMs });
    assert.equal(dis.status, "applied");
    assert.equal(app.devices.length, 0);
    assert.equal(app.scenes.length, 0);
    assert.equal(app.settings.haToken, "ha-tok-1");
    assert.equal(vaultData.get("ha_token"), "ha-tok-1");

    const savedAfterDisable = JSON.parse(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY)!) as Record<string, unknown>;
    assert.equal(savedAfterDisable["schemaVersion"], 1);
    assert.deepEqual(savedAfterDisable["futureCapabilityField"], { keep: 42 });
    assert.deepEqual(savedAfterDisable["disabledHaScopes"], [HA_SCOPE]);

    app.settings.haBaseURL = `${HA_URL}/api`;
    app.settings.haToken = "ha-tok-rotated";
    const rotated = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [],
      haBaseURL: app.settings.haBaseURL,
      haToken: app.settings.haToken,
      connectionMode: "homeAssistant",
      hasExistingPreferences: true,
    });
    assert.equal(haConnectionScope(app.settings.haBaseURL, app.settings.haToken), HA_SCOPE);
    assert.equal(rotated.disabledHaScopes.has(HA_SCOPE), true);
    assert.equal(rotated.selection.enabledConnections.includes("home-assistant"), false);
    assert.equal(rotated.selection.enabledConnectionScopes.includes(HA_SCOPE), false);
    assert.equal(rotated.knownDisabledHaDevices.some((d) => d.rawHaId === stripId && d.entityIds.includes("light.ha_strip")), true);
    assert.equal(rotated.knownDisabledHaScenes.some((s) => s.entityId === "scene.ha_movie"), true);

    const haExecBeforeDisconnect = h.countCmd("ha_execute");
    await disconnectHomeAssistantOnHost(app);
    assert.equal(h.countCmd("ha_execute"), haExecBeforeDisconnect);
    const afterDisconnect = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [],
      haBaseURL: null,
      haToken: null,
      hasExistingPreferences: true,
    });
    assert.equal(afterDisconnect.disabledHaScopes.size, 0);
    assert.equal(afterDisconnect.pendingRevalidationHaScopes.size, 0);
    assert.equal(afterDisconnect.knownDisabledHaDevices.length, 0);
    assert.equal(afterDisconnect.knownDisabledHaScenes.length, 0);
    assert.equal(queue.pausedScheduledCommands?.length ?? 0, 0);
    assert.deepEqual(queue.missedScheduledCommands.map((t) => t.id), ["t_ha_1"]);
  });

  it("drains in-flight HA IPC ('正在停止' -> '已停用') with zero new requests, discards late results, syncs set_service_endpoints, and queues rapid re-enable until drain completes", async () => {
    let pendingSnap: Deferred<Record<string, unknown>> | null = null;
    let pendingExec: Deferred<unknown> | null = null;
    const h = makeHarness({
      onHaSnapshot: async () => (pendingSnap ? pendingSnap.promise : makeHaSnapshotPayload()),
      onHaExecute: async () => (pendingExec ? pendingExec.promise : { ok: true }),
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-drain";

    await app.refreshHADevices(false);
    assert.equal(h.countCmd("ha_snapshot"), 1);

    pendingSnap = createDeferred<Record<string, unknown>>();
    pendingExec = createDeferred<unknown>();
    const inFlightRefresh = app.refreshHADevices(true);
    await new Promise<void>((resolve) => setImmediate(resolve));
    const inFlightClientExec = new HomeAssistantClient(HA_URL, "ha-tok-drain", h.invoke).execute({
      kind: "setLightPower",
      entityId: "light.ha_strip",
      isOn: false,
    });

    assert.equal(h.countCmd("ha_snapshot"), 2);
    assert.equal(h.countCmd("ha_execute"), 1);

    app.openSettingsSheet("connection");
    assert.ok(document.querySelector<HTMLInputElement>("[data-ha-connection-enabled]"));

    const disOutcome = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(disOutcome.status, "applied");
    assert.equal(getHostHaLifecyclePhase(app), "stopping");
    assert.match(document.body.textContent ?? "", /正在停止/);
    assert.ok(document.querySelector<HTMLInputElement>("[data-ha-connection-enabled]")?.disabled);

    const endpointCallsAfterDisable = h.tauriCalls.filter((c) => c.cmd === "set_service_endpoints");
    assert.ok(endpointCallsAfterDisable.length >= 1);
    assert.equal(endpointCallsAfterDisable.at(-1)?.args["haUrl"], "");
    assert.equal(app.settings.haBaseURL, HA_URL);

    const snapCountAtDisable = h.countCmd("ha_snapshot");
    const execCountAtDisable = h.countCmd("ha_execute");

    await app.refreshHADevices(false);
    await refreshDevices(app, false);
    await runUnsupportedDevicesScanOnHost(app);
    syncSensorHistoryHost(app);
    const historyPts = await fetchHomeAssistantSensorHistory({
      baseURL: HA_URL,
      token: "ha-tok-drain",
      transport: app.transport,
      entityIds: ["sensor.temp_living"],
      window: "24h",
    });
    assert.deepEqual(historyPts, []);
    await assert.rejects(() => new HomeAssistantClient(HA_URL, "ha-tok-drain", h.invoke).snapshot(), /turned off/i);
    await assert.rejects(
      () => new HomeAssistantProvider(new HomeAssistantClient(HA_URL, "ha-tok-drain", h.invoke)).execute({
        kind: "setLightPower",
        entityId: "light.ha_strip",
        isOn: false,
      }),
      /turned off/i,
    );
    assert.equal(h.countCmd("ha_snapshot"), snapCountAtDisable);
    assert.equal(h.countCmd("ha_execute"), execCountAtDisable);

    pendingSnap.resolve(makeHaSnapshotPayload());
    pendingExec.reject(new Error("late network error from old generation"));
    await Promise.allSettled([inFlightRefresh, inFlightClientExec]);
    await new Promise((r) => setTimeout(r, 0));

    assert.equal(getHostHaLifecyclePhase(app), "disabled");
    assert.equal(app.devices.length, 0);
    assert.equal(app.haConnectionError, null);
    assert.match(document.body.textContent ?? "", /已停用/);
    assert.match(document.body.textContent ?? "", /重新启用/);

    pendingSnap = null;
    pendingExec = null;
    await setHaConnectionEnabledOnHost(app, true);
    assert.equal(getHostHaLifecyclePhase(app), "enabled");
    assert.equal(app.devices.some((d) => d.name === "HA灯带"), true);

    const gen1Deferred = createDeferred<Record<string, unknown>>();
    let useDeferred = true;
    pendingSnap = {
      get promise() {
        return useDeferred ? gen1Deferred.promise : Promise.resolve(makeHaSnapshotPayload());
      },
      resolve: gen1Deferred.resolve,
      reject: gen1Deferred.reject,
    };
    const beforeGen1 = h.countCmd("ha_snapshot");
    const hungGen1 = app.refreshHADevices(true);
    await new Promise<void>((resolve) => setImmediate(resolve));
    const snapsWhenGen1Started = h.countCmd("ha_snapshot");
    assert.equal(snapsWhenGen1Started, beforeGen1 + 1);

    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(getHostHaLifecyclePhase(app), "stopping");

    useDeferred = false;
    pendingSnap = null;
    let reenableSettled = false;
    const reenablePromise = setHaConnectionEnabledOnHost(app, true).then((res) => {
      reenableSettled = true;
      return res;
    });
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(reenableSettled, false);
    assert.equal(h.countCmd("ha_snapshot"), snapsWhenGen1Started);

    gen1Deferred.resolve(makeHaSnapshotPayload());
    await hungGen1;
    const reenableRes = await reenablePromise;
    assert.equal(reenableRes.status, "applied");
    assert.equal(getHostHaLifecyclePhase(app), "enabled");
    assert.equal(h.countCmd("ha_snapshot"), snapsWhenGen1Started + 1);
    assert.equal(h.tauriCalls.filter((c) => c.cmd === "set_service_endpoints").pop()?.args["haUrl"], HA_URL);
    assert.equal(app.devices.some((d) => d.name === "HA灯带"), true);
  });

  it("previews affected timers/automations/quickActions, supports cancel & atomic rollback, and revalidates only after fresh HA snapshot on re-enable", async () => {
    let failNextSnapshot = false;
    const h = makeHarness({
      onHaSnapshot: async () => {
        if (failNextSnapshot) throw new Error("HA temporarily unreachable");
        return makeHaSnapshotPayload();
      },
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-preflight";

    await app.refreshHADevices(false);
    markTimerSnapshotReady(app);

    const stripId = app.devices.find((d) => d.name === "HA灯带")!.id;
    const nowMs = 1_760_500_000_000;
    const identity = scheduledCommandIdentity(app.settings)!;
    const queue = app.scheduledCommandStore.queue(identity);
    queue.scheduledCommands = [
      {
        id: "t_future_valid",
        command: "十分钟后关HA灯带",
        reply: "好",
        delaySeconds: 600,
        fireTimestampMs: nowMs + 600_000,
        intents: [{ targetId: stripId, operation: { kind: "power", isOn: false } }],
      },
      {
        id: "t_will_expire",
        command: "一分钟后关HA灯带",
        reply: "好",
        delaySeconds: 60,
        fireTimestampMs: nowMs + 60_000,
        intents: [{ targetId: stripId, operation: { kind: "power", isOn: false } }],
      },
    ];
    queue.missedScheduledCommands = [{
      id: "t_missed_scene",
      command: "开启HA影院模式",
      reply: "好",
      delaySeconds: 30,
      fireTimestampMs: nowMs - 10_000,
      intents: [{ targetId: "scene.ha_movie", operation: { kind: "activateScene" } }],
    }];
    const foreignQueue = app.scheduledCommandStore.queue(JSON.stringify(["xiaomiCloud", SESS_A.userId, "cn"]));
    foreignQueue.scheduledCommands = [{
      id: "t_foreign_ha",
      command: "跨源关HA灯带",
      reply: "好",
      delaySeconds: 300,
      fireTimestampMs: nowMs + 300_000,
      intents: [{ targetId: stripId, operation: { kind: "power", isOn: false } }],
      sourceScopes: [HA_SCOPE, ACC_A],
    }];
    app.scheduledCommandStore.persist();

    const ruleStore = new AutomationRuleStore(localStorage);
    ruleStore.save([
      createAutomationRule({ id: "r_ha_dev", isEnabled: true, trigger: "screenLocked", action: { kind: "devices", deviceIds: [stripId], isOn: false } }),
      createAutomationRule({ id: "r_ha_qa", isEnabled: true, trigger: "screenLocked", action: { kind: "quickAction", quickAction: "lightsOff" } }),
    ]);

    const directPreview = previewHaConnectionDisable({
      haScope: HA_SCOPE,
      context: buildHostCapabilityContext(app),
      scheduledCommandStore: app.scheduledCommandStore,
      activeTimerIdentity: identity,
      ruleStore,
    });
    assert.equal(directPreview.disposition, "requiresPauseConfirmation");
    const previewIds = new Set(directPreview.itemsToPause.map((i) => `${i.kind}:${i.id}`));
    for (const expected of [
      "waitingTimer:t_future_valid",
      "waitingTimer:t_will_expire",
      "missedTimer:t_missed_scene",
      "foreignTimer:t_foreign_ha",
      "automationRule:r_ha_dev",
      "automationRule:r_ha_qa",
      "quickAction:lightsOff",
    ]) {
      assert.equal(previewIds.has(expected), true);
    }

    app.openSettingsSheet("connection");
    const firstAsk = await setHaConnectionEnabledOnHost(app, false, { nowMs });
    assert.equal(firstAsk.status, "requiresPauseConfirmation");
    assert.equal(document.querySelector<HTMLInputElement>("[data-ha-connection-enabled]")?.checked, true);
    document.querySelector<HTMLButtonElement>("[data-ha-cancel-disable]")!.click();
    assert.equal(isHostHaEnabled(app), true);
    assert.equal(queue.scheduledCommands.length, 2);
    assert.equal(ruleStore.load().every((r) => r.isEnabled), true);

    const rawSelectionBefore = localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
    const rawTimersBefore = localStorage.getItem(SCHEDULED_COMMANDS_STORAGE_KEY);
    const rawRulesBefore = localStorage.getItem(AutomationRuleStore.storageKey);
    const origSetItem = localStorage.setItem.bind(localStorage);
    for (const failKey of [MI_ACCOUNT_CAPABILITY_STORAGE_KEY, SCHEDULED_COMMANDS_STORAGE_KEY, AutomationRuleStore.storageKey]) {
      let activeFail = true;
      Object.defineProperty(localStorage, "setItem", {
        configurable: true,
        writable: true,
        value: (k: string, v: string): void => {
          if (activeFail && k === failKey) throw new Error("QuotaExceededError");
          origSetItem(k, v);
        },
      });
      try {
        const failedCommit = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true, nowMs });
        assert.equal(failedCommit.status, "blocked");
      } finally {
        activeFail = false;
        Object.defineProperty(localStorage, "setItem", { configurable: true, writable: true, value: origSetItem });
      }
      assert.equal(isHostHaEnabled(app), true);
      assert.equal(localStorage.getItem(MI_ACCOUNT_CAPABILITY_STORAGE_KEY), rawSelectionBefore);
      assert.equal(localStorage.getItem(SCHEDULED_COMMANDS_STORAGE_KEY), rawTimersBefore);
      assert.equal(localStorage.getItem(AutomationRuleStore.storageKey), rawRulesBefore);
      assert.equal(queue.scheduledCommands.length, 2);
      assert.equal(queue.pausedScheduledCommands?.length ?? 0, 0);
      assert.equal(ruleStore.load().every((r) => r.isEnabled), true);
    }

    const committed = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true, nowMs });
    assert.equal(committed.status, "applied");
    assert.equal(isHostHaEnabled(app), false);
    assert.equal(queue.scheduledCommands.length, 0);
    assert.equal(queue.missedScheduledCommands.length, 0);
    assert.equal(queue.pausedScheduledCommands?.length, 3);
    assert.equal(foreignQueue.pausedScheduledCommands?.length, 1);
    assert.equal(ruleStore.load().every((r) => !r.isEnabled && r.pausedByCapabilities?.length), true);

    failNextSnapshot = true;
    const execBeforeReenable = h.countCmd("ha_execute");
    await setHaConnectionEnabledOnHost(app, true, { nowMs: nowMs + 120_000 });
    const stateAfterFailedSnap = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [],
      haBaseURL: HA_URL,
      haToken: "ha-tok-preflight",
      connectionMode: "homeAssistant",
      hasExistingPreferences: true,
    });
    assert.equal(stateAfterFailedSnap.pendingRevalidationHaScopes.has(HA_SCOPE), true);
    assert.equal(queue.pausedScheduledCommands?.length, 3);
    assert.equal(ruleStore.load().every((r) => !r.isEnabled), true);
    assert.equal(h.countCmd("ha_execute"), execBeforeReenable);

    failNextSnapshot = false;
    (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs = nowMs + 120_000;
    try {
      await app.refreshHADevices(false);
    } finally {
      delete (app as unknown as { pendingReenableNowMs?: number }).pendingReenableNowMs;
    }
    processScheduledCommands(app, nowMs + 120_000);
    assert.equal(h.countCmd("ha_execute"), execBeforeReenable);
    assert.deepEqual(queue.scheduledCommands.map((t) => t.id), ["t_future_valid"]);
    assert.deepEqual(new Set(queue.missedScheduledCommands.map((t) => t.id)), new Set(["t_will_expire", "t_missed_scene"]));
    assert.equal(queue.pausedScheduledCommands?.length ?? 0, 0);
    assert.equal(ruleStore.load().every((r) => r.isEnabled), true);
    const stateAfterGoodSnap = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [],
      haBaseURL: HA_URL,
      haToken: "ha-tok-preflight",
      connectionMode: "homeAssistant",
      hasExistingPreferences: true,
    });
    assert.equal(stateAfterGoodSnap.pendingRevalidationHaScopes.has(HA_SCOPE), false);
    assert.equal(stateAfterGoodSnap.pausedQuickActionIds.has("lightsOff"), false);
  });

  it("isolates dual-source HA disable: keeps paired Xiaomi+HA device online via Xiaomi with 0 HA calls, snapshots only pure-HA items, preserves Xiaomi camera live, and reports accurate footer status", async () => {
    const h = makeHarness({
      onHaSnapshot: async () =>
        makeHaSnapshotPayload({
          devices: [
            { id: "ha-dev-paired", name: "吸顶主灯", area_id: "living", identifiers: [["xiaomi_home", "cn_101"]], connections: [["mac", "aa:bb:cc:dd:ee:01"]] },
            { id: "ha-dev-strip", name: "HA灯带", area_id: "living" },
            { id: "ha-dev-cam", name: "HA门廊摄像机", area_id: "living" },
          ],
          entities: [
            { entity_id: "light.paired_ceiling", device_id: "ha-dev-paired" },
            { entity_id: "light.ha_strip", device_id: "ha-dev-strip" },
            { entity_id: "camera.ha_porch", device_id: "ha-dev-cam" },
          ],
          states: [
            { entity_id: "light.paired_ceiling", state: "on", attributes: { friendly_name: "吸顶主灯", brightness: 200, supported_color_modes: ["brightness"] } },
            { entity_id: "light.ha_strip", state: "on", attributes: { friendly_name: "HA灯带", brightness: 180, supported_color_modes: ["brightness"] } },
            { entity_id: "camera.ha_porch", state: "streaming", attributes: { friendly_name: "HA门廊摄像机" } },
            { entity_id: "scene.ha_movie", state: "scenic", attributes: { friendly_name: "HA影院模式" } },
          ],
        }),
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-dual";
    app.settings.miSession = SESS_A;
    setHostDualSourceEnabled(app, true, { persist: true });
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);

    await refreshDevices(app, false);
    const pairedBefore = app.devices.find((d) => d.name === "吸顶主灯")!;
    const haOnlyBefore = app.devices.find((d) => d.name === "HA灯带")!;
    const miCam = app.devices.find((d) => d.name === "客厅摄像机")!;
    const haCam = app.devices.find((d) => d.name === "HA门廊摄像机")!;
    assert.ok(pairedBefore && haOnlyBefore && miCam && haCam);

    setHostDeviceSourcePin(app, pairedBefore.id, "homeAssistant");
    app.cameraLive.activeLiveCameraId = haCam.id;
    app.cameraLive.liveCameraKeepAliveTimer = window.setInterval(() => {}, 15_000);
    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(app.cameraLive.activeLiveCameraId, null);
    assert.equal(app.cameraLive.liveCameraKeepAliveTimer, null);

    await setHaConnectionEnabledOnHost(app, true);
    const miCamAfterReenable = app.devices.find((d) => d.name === "客厅摄像机")!;
    app.cameraLive.activeLiveCameraId = miCamAfterReenable.id;
    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(app.cameraLive.activeLiveCameraId, miCamAfterReenable.id);

    assert.equal(app.devices.some((d) => d.name === "HA灯带"), false);
    assert.equal(app.scenes.some((s) => s.name === "HA影院模式"), false);
    const pairedAfter = app.devices.find((d) => d.name === "吸顶主灯")!;
    assert.ok(pairedAfter);
    assert.equal(pairedAfter.id, pairedBefore.id);

    const dualState = resolveMiAccountSelectionState({
      storage: localStorage,
      accounts: [makeMiAccount(SESS_A)],
      haBaseURL: HA_URL,
      haToken: "ha-tok-dual",
      connectionMode: "homeAssistant",
      dualSourceEnabled: true,
      hasExistingPreferences: true,
    });
    assert.equal(dualState.knownDisabledHaDevices.some((d) => d.name === "HA灯带"), true);
    assert.equal(dualState.knownDisabledHaDevices.some((d) => d.name === "吸顶主灯"), false);

    const haSnapBefore = h.countCmd("ha_snapshot");
    const haExecBefore = h.countCmd("ha_execute");
    const miWritesBefore = h.miWritePaths.length;

    assert.equal(
      await app.applyCommand({ kind: "setLightPower", entityId: devicePrimaryEntityId(pairedAfter)!, isOn: false }),
      true,
    );
    assert.equal(h.miWritePaths.length, miWritesBefore + 1);
    assert.equal(h.countCmd("ha_execute"), haExecBefore);

    await refreshDevices(app, false);
    await runUnsupportedDevicesScanOnHost(app);
    assert.equal(h.countCmd("ha_snapshot"), haSnapBefore);

    const dualHealthyMiStatus = resolveConnectionStatus(app);
    assert.equal(dualHealthyMiStatus.tone, "online");
    assert.match(dualHealthyMiStatus.sources.find((s) => s.id === "ha")?.statusText ?? dualHealthyMiStatus.text, /已停用/);

    await setMiAccountEnabledOnHost(app, ACC_A, false, { confirmPause: true });
    assert.match(resolveConnectionStatus(app).text, /已停用/);

    setHostDualSourceEnabled(app, false, { persist: true });
    app.settings.connectionMode = "homeAssistant";
    assert.match(resolveConnectionStatus(app).text, /Home Assistant 已停用/);
    app.settings.interfaceLanguage = "en";
    setLanguage("en");
    try {
      assert.match(resolveConnectionStatus(app).text, /Home Assistant is turned off/);
    } finally {
      setLanguage("zh-Hans");
    }
  });

  it("enforces unified host write gate across all control entry points before requiresConfirmation and lock-screen checks with 0 hardware writes", async () => {
    const h = makeHarness({ workstationLocked: true });
    const { app } = h;
    const bannerText = (): string => app.replyBanner?.text ?? "";
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-gate";
    app.settings.blockControlWhileLocked = false;
    app.settings.panelTheme = "fluent";

    await app.refreshHADevices(false);
    markTimerSnapshotReady(app);

    const stripDev = app.devices.find((d) => d.name === "HA灯带")!;
    const heaterDev = app.devices.find((d) => d.name === "HA取暖器插座")!;
    assert.ok(stripDev && heaterDev);
    app.layout.aliases[stripDev.id] = "玄关氛围带";

    await app.executeSingleCommand(
      stripDev,
      { kind: "setLightPower", entityId: devicePrimaryEntityId(stripDev)!, isOn: false },
      "已关闭 HA灯带",
    );
    assert.ok(app.lastUndoAction);

    await app.handleNaturalCommand("打开HA取暖器插座");
    assert.ok(app.pendingSuggestions.length > 0);
    const heaterCmd = { kind: "setSwitch" as const, entityId: "switch.ha_heater", isOn: true };
    app.setPendingHighRisk({
      deviceId: heaterDev.id,
      actionKey: JSON.stringify(heaterCmd),
      expiresAtMs: Date.now() + 30_000,
      sourceRevision: app.sourceRevision,
      confirm: {
        command: heaterCmd,
        summary: "已打开HA取暖器插座",
        intent: { targetId: heaterDev.id, operation: { kind: "power", isOn: true } },
        promptLabel: "打开HA取暖器插座",
      },
    });
    app.render();
    assert.ok(document.querySelector<HTMLElement>(`[data-high-risk-confirm="${heaterDev.id}"]`));

    const dis = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(dis.status, "applied");
    assert.equal(app.pendingHighRisk, null);
    assert.equal(app.pendingSuggestions.length, 0);
    assert.equal(app.lastUndoAction, null);

    const haExecBaseline = h.countCmd("ha_execute");
    const miWriteBaseline = h.miWritePaths.length;

    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "light.ha_strip", isOn: true }), false);
    assert.match(bannerText(), /Home Assistant 已停用/);

    assert.equal(await app.applyCommand({ kind: "activateScene", entityId: "scene.ha_movie" }), false);
    assert.match(bannerText(), /Home Assistant 已停用/);

    await app.executeSingleCommand(heaterDev, { kind: "setSwitch", entityId: "switch.ha_heater", isOn: true }, "打开取暖器");
    assert.match(bannerText(), /Home Assistant 已停用/);

    const ghostHeater: SmartDevice = {
      ...heaterDev,
      id: "ha:switch.ghost_heater",
      name: "幽灵取暖器插座",
      kind: { kind: "plug", switchEntityId: "switch.ghost_heater", isOn: false, powerWatts: null, energyKwh: null, childLockEntityId: null, isChildLocked: false },
    };
    await app.executeSingleCommand(ghostHeater, { kind: "setSwitch", entityId: "switch.ghost_heater", isOn: true }, "打开幽灵取暖器");
    assert.match(bannerText(), /设备不存在/);
    assert.equal(app.pendingHighRisk, null);

    assert.equal(await app.applyCommand({ kind: "activateScene", entityId: "scene.ghost_scene" }), false);
    assert.match(bannerText(), /场景不存在/);

    await (app as unknown as { turnAllOff(): Promise<void> }).turnAllOff();
    assert.match(bannerText(), /Home Assistant 已停用/);

    await executeBuiltInQuickAction(app, "lightsOff");
    assert.match(bannerText(), /已随关联连接停用而暂停|Home Assistant 已停用/);

    await executeBuiltInQuickAction(app, "climateSleepOff");
    assert.match(bannerText(), /Home Assistant 已停用/);

    app.lastUndoAction = {
      summary: "旧撤销",
      steps: [{ deviceId: stripDev.id, commands: [{ kind: "setLightPower", entityId: "light.ha_strip", isOn: true }] }],
      expiresAtMs: Date.now() + 60_000,
    };
    await app.performUndo();
    assert.match(bannerText(), /Home Assistant 已停用/);
    assert.equal(app.lastUndoAction, null);

    getHostActivityCenter(app).recentAutomationRuns = [{
      id: "run_stale_ha",
      ruleId: "r_stale",
      trigger: "systemWake",
      triggerTitle: "唤醒",
      summary: "已关闭 HA灯带",
      steps: [{ deviceId: stripDev.id, commands: [{ kind: "setLightPower", entityId: "light.ha_strip", isOn: true }] }],
      kindSnapshots: new Map(),
      scope: HA_SCOPE,
      firedAtMs: Date.now() - 1_000,
      expiresAtMs: Date.now() + 60_000,
    }];
    await executeAutomationCardUndo(app, "run_stale_ha");
    assert.match(bannerText(), /Home Assistant 已停用/);

    app.pendingSuggestions = [{
      id: "confirm:stale_ha",
      title: "确认打开HA取暖器插座",
      confidencePercent: null,
      intents: [{ targetId: heaterDev.id, operation: { kind: "power", isOn: true } }],
    }];
    app.isShowingAssistantBar = true;
    app.render();
    document.querySelector<HTMLElement>('[data-suggestion-id="confirm:stale_ha"]')!.click();
    assert.match(bannerText(), /Home Assistant 已停用/);
    assert.equal(app.pendingSuggestions.length, 0);

    await setHaConnectionEnabledOnHost(app, true);
    app.replyBanner = null;
    app.setPendingHighRisk({
      deviceId: heaterDev.id,
      actionKey: JSON.stringify(heaterCmd),
      expiresAtMs: Date.now() + 30_000,
      sourceRevision: app.sourceRevision,
      confirm: {
        command: heaterCmd,
        summary: "已打开HA取暖器插座",
        intent: { targetId: heaterDev.id, operation: { kind: "power", isOn: true } },
        promptLabel: "打开HA取暖器插座",
      },
    });
    app.render();
    const liveCardConfirmBtn = document.querySelector<HTMLElement>(`[data-high-risk-confirm="${heaterDev.id}"]`)!;
    writeMiAccountSelectionMutation({
      mutate: (prev) => ({
        ...prev,
        disabledHaScopes: [...new Set([...prev.disabledHaScopes, HA_SCOPE])],
      }),
    });
    liveCardConfirmBtn.click();
    assert.match(bannerText(), /Home Assistant 已停用/);
    assert.equal(app.pendingHighRisk, null);
    await setHaConnectionEnabledOnHost(app, true);
    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });

    const urlToasts: string[] = [];
    let urlConfirmHandler: () => Promise<boolean> = async () => true;
    const makeUrlHost = (): AppURLCommandHost => ({
      get devices() { return app.devices; },
      get scenes() { return app.scenes; },
      get settings() { return app.settings; },
      get layout() { return app.layout; },
      get sourceRevision() { return app.sourceRevision; },
      get pendingHighRisk() { return app.pendingHighRisk; },
      get replyBanner() { return app.replyBanner; },
      pendingConsent: null,
      expandedDeviceId: null,
      isControlBlockedByScreenLock: async () => false,
      getActiveRaycastBridgeToken: () => undefined,
      revealPanelForExternalUrl: async () => {},
      requestExternalUrlConfirmation: () => urlConfirmHandler(),
      setPendingHighRisk: (v) => { app.pendingHighRisk = v; },
      clearPendingHighRisk: () => { app.clearPendingHighRisk(); },
      showExternalToast: (msg: string) => { urlToasts.push(msg); },
      recordRaycastCommandFeedback: () => {},
      executeSingleCommand: (d, c, s, i, r) => app.executeSingleCommand(d, c, s, i, r),
      applyCommand: (c, r) => app.applyCommand(c, r),
      updateUndoCommandsForDevice: () => {},
      handleNaturalCommand: (u, f) => app.handleNaturalCommand(u, f),
      executeBuiltInSceneFromUrl: async () => ({ message: "", isError: false }),
      focusDeviceFromUrl: () => "focused" as const,
    });
    for (const url of [
      `menumijia://power?device=${encodeURIComponent(stripDev.id)}&state=on`,
      "menumijia://toggle?device=light.ha_strip",
      "menumijia://brightness?device=ha%E7%81%AF%E5%B8%A6&percent=50",
      "menumijia://power?device=%E7%8E%84%E5%85%B3%E6%B0%9B%E5%9B%B4%E5%B8%A6&state=off",
      "menumijia://scene?name=ha%E5%BD%B1%E9%99%A2%E6%A8%A1%E5%BC%8F",
      "menumijia://scene?name=scene.ha_movie",
      "menumijia://ask?text=%E6%89%93%E5%BC%80HA%E7%81%AF%E5%B8%A6",
    ]) {
      await onOpenURL(url, makeUrlHost());
      assert.match(urlToasts.at(-1) ?? "", /Home Assistant 已停用/);
    }
    await onOpenURL("menumijia://power?device=nonexistent_lamp_xyz&state=on", makeUrlHost());
    assert.doesNotMatch(urlToasts.at(-1) ?? "", /Home Assistant 已停用/);
    assert.match(urlToasts.at(-1) ?? "", /不存在|尚未加载/);

    await setHaConnectionEnabledOnHost(app, true);
    app.settings.allowDirectURLControl = false;
    const urlConfirmDeferred = createDeferred<boolean>();
    urlConfirmHandler = () => urlConfirmDeferred.promise;
    const inFlightUrl = onOpenURL(`menumijia://power?device=${encodeURIComponent(stripDev.id)}&state=off`, makeUrlHost());
    await new Promise((r) => setTimeout(r, 0));
    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    urlConfirmDeferred.resolve(true);
    await inFlightUrl;
    assert.match(urlToasts.at(-1) ?? "", /Home Assistant 已停用/);

    app.settings.assistantBaseURL = "http://127.0.0.1:11434/v1";
    const aiCountBefore = h.aiRequests.length;
    for (const cmd of ["打开HA灯带", "五分钟后关闭HA灯带", "开启HA影院模式"]) {
      await app.handleNaturalCommand(cmd);
      assert.match(bannerText(), /Home Assistant 已停用/);
    }
    assert.equal(h.aiRequests.length, aiCountBefore);

    app.settings.blockControlWhileLocked = true;
    const identity = scheduledCommandIdentity(app.settings)!;
    const queue = app.scheduledCommandStore.queue(identity);
    queue.missedScheduledCommands = [{
      id: "t_missed_disabled_ha",
      command: "关闭HA灯带",
      reply: "好",
      delaySeconds: 60,
      fireTimestampMs: Date.now() - 5_000,
      intents: [{ targetId: stripDev.id, operation: { kind: "power", isOn: false } }],
    }];
    app.missedScheduledCommands = queue.missedScheduledCommands;
    app.scheduledCommandStore.persist();
    const lockChecksBeforeMissed = h.lockChecks;
    await confirmMissedScheduledCommand(app, "t_missed_disabled_ha");
    assert.equal(h.lockChecks, lockChecksBeforeMissed);
    assert.match(bannerText(), /Home Assistant 已停用/);

    await app.runScheduledCommand({
      id: "t_direct_disabled_ha",
      command: "关闭HA灯带",
      reply: "好",
      delaySeconds: 10,
      fireTimestampMs: Date.now(),
      intents: [{ targetId: stripDev.id, operation: { kind: "power", isOn: false } }],
    });
    assert.match(bannerText(), /Home Assistant 已停用/);

    app.settings.miSession = SESS_A;
    setHostDualSourceEnabled(app, true, { persist: true });
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);
    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    const validMiLight = app.devices.find((d) => d.name === "米家台灯")!;
    assert.ok(validMiLight);

    const okPartialIntents = await app.executeIntents(
      [
        { targetId: validMiLight.id, operation: { kind: "power", isOn: false } },
        { targetId: stripDev.id, operation: { kind: "power", isOn: false } },
      ],
      "批量关灯",
      "快捷测试",
    );
    assert.equal(okPartialIntents, false);
    assert.match(bannerText(), /Home Assistant 已停用/);

    await app.runScheduledCommand({
      id: "t_partial_missing",
      command: "残缺定时计划",
      reply: "好",
      delaySeconds: 10,
      fireTimestampMs: Date.now(),
      intents: [
        { targetId: validMiLight.id, operation: { kind: "power", isOn: false } },
        { targetId: "missing_device_999", operation: { kind: "power", isOn: false } },
      ],
    });
    assert.match(bannerText(), /设备不存在/);

    let confirmHandlerCalls = 0;
    (app as unknown as { manualControlConfirmationHandler?: () => boolean }).manualControlConfirmationHandler = () => {
      confirmHandlerCalls += 1;
      return true;
    };
    const partialMissingRule = createAutomationRule({
      id: "r_partial_missing",
      isEnabled: true,
      trigger: "screenLocked",
      action: { kind: "devices", deviceIds: [validMiLight.id, "switch.ghost_heater"], isOn: true },
    });
    const lockBeforeAuto = h.lockChecks;
    assert.equal(await executeAutomationRule(app, partialMissingRule), null);
    assert.equal(confirmHandlerCalls, 0);
    assert.equal(h.lockChecks, lockBeforeAuto);
    assert.match(bannerText(), /设备不存在/);

    const partialDisabledHaRule = createAutomationRule({
      id: "r_partial_disabled_ha",
      isEnabled: true,
      trigger: "systemWake",
      action: { kind: "devices", deviceIds: [validMiLight.id, stripDev.id], isOn: false },
    });
    new AutomationRuleStore(localStorage).save([partialDisabledHaRule]);
    const dispatched = await dispatchSystemContextEvent(app, { kind: "systemWake" }, Date.now() + 120_000);
    assert.equal(dispatched.length, 0);
    assert.match(bannerText(), /Home Assistant 已停用/);

    assert.equal(h.countCmd("ha_execute"), haExecBaseline);
    assert.equal(h.miWritePaths.length, miWriteBaseline);
  });

  it("exposes the HA disable checkbox by default and supports recovery when the feature is gated off", async () => {
    setHaNativeCancelReadyForTests(null);
    assert.equal(isHaNativeCancelReady(), true);

    const h = makeHarness();
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-gate";
    await app.refreshHADevices(false);

    app.openSettingsSheet("connection");
    assert.ok(document.querySelector("[data-ha-connection-enabled]"));
    assert.ok(document.querySelector("#btn-disconnect-ha"));

    setHaNativeCancelReadyForTests(false);
    app.render();
    assert.equal(document.querySelector("[data-ha-connection-enabled]"), null);

    writeMiAccountSelectionMutation({
      storage: localStorage,
      mutate: (prev) => ({ ...prev, disabledHaScopes: [HA_SCOPE] }),
    });
    app.devices = [];
    app.scenes = [];
    app.render();

    assert.equal(document.querySelector("[data-ha-connection-enabled]"), null);
    assert.equal(document.querySelector("[data-ha-connection-status]")?.getAttribute("data-ha-connection-status"), "disabled");
    assert.ok(document.querySelector<HTMLButtonElement>("[data-ha-reenable]"));

    app.activeSheet = "none";
    app.render();
    assert.match(document.querySelector("#empty-ha-disabled")?.textContent ?? "", /Home Assistant 已停用/);
    document.querySelector<HTMLButtonElement>("#btn-empty-ha-reenable")!.click();
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(isHostHaEnabled(app), true);
    assert.equal(app.devices.some((d) => d.name === "HA灯带"), true);
  });

  it("keeps HA stopping until native drain completes, ref's awaited drain timers, recovers from rejected native drain, and maps stale-registration errors", async () => {
    setHaStopDrainTimeoutMsForTests(20);
    const lease = acquireHaTransportLease(HA_URL)!;
    assert.ok(lease);
    assert.equal(beginHaScopeDisable(HA_SCOPE), "stopping");
    assert.equal(isHaDrainTimerRefedForTests(HA_SCOPE), false);
    let refedWhileAwaited: boolean | null = null;
    const drained = await new Promise<{ ready: boolean; timedOut: boolean }>((resolve) => {
      requestHaScopeEnableAfterDrain(HA_SCOPE, (ready, meta) => resolve({ ready, timedOut: Boolean(meta?.timedOut) }));
      refedWhileAwaited = isHaDrainTimerRefedForTests(HA_SCOPE);
    });
    assert.equal(refedWhileAwaited, true);
    assert.deepEqual(drained, { ready: false, timedOut: true });
    assert.equal(getHaScopeLifecyclePhase(HA_SCOPE), "stop_timeout");
    lease.release();
    resetHaTransportGateForTests();
    setHaNativeCancelReadyForTests(true);

    const STALE_TEXT = "Home Assistant connection is disabled or has changed";
    const staleClient = new HomeAssistantClient(HA_URL, "ha-tok-stale", async () => {
      throw STALE_TEXT;
    });
    await assert.rejects(staleClient.snapshot(), (error: unknown) => {
      assert.ok(isHaBlockedRequestError(error));
      assert.equal(error.scope, HA_SCOPE);
      assert.equal(String(error.message).includes(STALE_TEXT), false);
      return true;
    });

    (window as unknown as { __TAURI_INTERNALS__?: { invoke: unknown } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string): Promise<never> => {
        assert.equal(cmd, "ha_http");
        throw STALE_TEXT;
      },
    };
    await assert.rejects(
      createTransport()({
        url: `${HA_URL}/api/states`,
        haConnection: { baseUrl: HA_URL, generation: 7, signal: new AbortController().signal },
      }),
      (error: unknown) => isHaBlockedRequestError(error),
    );

    const oldDrain = createDeferred<void>();
    const newReady = createDeferred<void>();
    const nextURL = "https://next-ha.example/house";
    let rejectStop = false;
    const h = makeHarness({
      onHaSetConnection: ({ baseUrl }) => {
        if (baseUrl === null && rejectStop) return Promise.reject(new Error("native drain unavailable"));
        if (baseUrl === null) return oldDrain.promise;
        if (baseUrl === nextURL) return newReady.promise;
        return Promise.resolve();
      },
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-first";
    app.submitServiceEndpoints();
    await app.refreshHADevices(false);
    const first = h.tauriCalls.find((call) => call.cmd === "ha_snapshot")!;
    const firstRegistration = h.tauriCalls.find((call) => call.cmd === "ha_set_connection")!;
    assert.equal(first.args["generation"], firstRegistration.args["generation"]);

    await fetchHomeAssistantSensorHistory({
      baseURL: HA_URL,
      token: "ha-first",
      transport: createTransport(),
      entityIds: ["sensor.ha_temp"],
      window: "24h",
    });
    assert.equal(h.tauriCalls.find((call) => call.cmd === "ha_http")?.args["generation"], firstRegistration.args["generation"]);

    // #292 N1: `ha_http` is read-only, so a write is refused before any IPC instead of being
    // downgraded to a GET, and an already-aborted lease never reaches the native command.
    const haHttpCallsBefore = h.countCmd("ha_http");
    const haLeaseSignal = new AbortController();
    await assert.rejects(
      createTransport()({
        url: `${HA_URL}/api/services/light/turn_on`,
        method: "POST",
        body: JSON.stringify({ entity_id: "light.ha_strip" }),
        haConnection: { baseUrl: HA_URL, generation: 7, signal: haLeaseSignal.signal },
      }),
      /only supports GET requests/,
    );
    assert.equal(h.countCmd("ha_http"), haHttpCallsBefore);
    haLeaseSignal.abort();
    await assert.rejects(
      createTransport()({
        url: `${HA_URL}/api/states`,
        haConnection: { baseUrl: HA_URL, generation: 7, signal: haLeaseSignal.signal },
      }),
      (error: unknown) => error instanceof Error && error.name === "AbortError",
    );
    assert.equal(h.countCmd("ha_http"), haHttpCallsBefore);

    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(getHostHaLifecyclePhase(app), "stopping");
    const stop = h.tauriCalls.find((call) => call.cmd === "ha_set_connection" && call.args["baseUrl"] === null)!;
    assert.ok(Number(stop.args["generation"]) > Number(first.args["generation"]));

    app.settings.haBaseURL = nextURL;
    app.settings.haToken = "ha-next";
    app.submitServiceEndpoints();
    const refresh = app.refreshHADevices(false);
    oldDrain.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(h.countCmd("ha_snapshot"), 1);
    newReady.resolve();
    await refresh;
    const last = h.tauriCalls.filter((call) => call.cmd === "ha_snapshot").at(-1)!;
    const nextRegistration = h.tauriCalls.find((call) => call.cmd === "ha_set_connection" && call.args["baseUrl"] === nextURL)!;
    assert.equal(last.args["baseUrl"], nextURL);
    assert.equal(last.args["generation"], nextRegistration.args["generation"]);
    assert.ok(Number(last.args["generation"]) > Number(stop.args["generation"]));

    app.settings.connectionMode = "demo";
    await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    await app.endpointSubmission;
    await setHaConnectionEnabledOnHost(app, true);
    await app.endpointSubmission;
    const demoRegistration = h.tauriCalls.filter((call) => call.cmd === "ha_set_connection").at(-1)!;
    assert.equal(demoRegistration.args["baseUrl"], nextURL);
    assert.ok(Number(demoRegistration.args["generation"]) > Number(last.args["generation"]));
    assert.equal(h.countCmd("ha_snapshot"), 2);

    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.submitServiceEndpoints();
    await app.endpointSubmission;
    rejectStop = true;
    const nextScope = haConnectionScope(HA_URL, app.settings.haToken)!;
    const disReject = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(disReject.status, "applied");
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(getHaScopeInFlightCount(nextScope), 0);
    assert.equal(isHaScopeStopTimedOut(nextScope), false);
    assert.equal(getHostHaLifecyclePhase(app), "disabled");
    rejectStop = false;
    const reenabledAfterReject = await setHaConnectionEnabledOnHost(app, true);
    assert.equal(reenabledAfterReject.status, "applied");
    assert.equal(isHostHaEnabled(app), true);
  });

  it("bounds hung HA in-flight stop with stop_timeout, surfaces Still stopping · Retry without hanging setHaConnectionEnabledOnHost(true), and abandons stale leases cleanly", async () => {
    setHaStopDrainTimeoutMsForTests(25);
    const hungSnapshot = createDeferred<ReturnType<typeof makeHaSnapshotPayload>>();
    let useHungSnapshot = true;

    const h = makeHarness({
      onHaSnapshot: async () => {
        if (useHungSnapshot) return hungSnapshot.promise;
        return makeHaSnapshotPayload({
          devices: [{ id: "ha-dev-fresh", name: "恢复后新灯", area_id: "living" }],
          entities: [{ entity_id: "light.ha_fresh", device_id: "ha-dev-fresh" }],
          states: [{ entity_id: "light.ha_fresh", state: "on", attributes: { friendly_name: "恢复后新灯", brightness: 200 } }],
        });
      },
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-hung";

    const inFlightRefresh = app.refreshHADevices(false);
    await new Promise((r) => setTimeout(r, 0));

    const dis = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true });
    assert.equal(dis.status, "applied");
    assert.equal(getHostHaLifecyclePhase(app), "stopping");

    const blockedReenable = await setHaConnectionEnabledOnHost(app, true);
    assert.equal(blockedReenable.status, "blocked");
    assert.equal(isHostHaEnabled(app), false);
    assert.equal(getHostHaLifecyclePhase(app), "stop_timeout");
    assert.match(resolveConnectionStatus(app).text, /还在停止 · 重试/);

    app.activeSheet = "none";
    app.render();
    assert.ok(document.querySelector("#btn-empty-ha-stop-retry"));
    assert.ok(document.querySelector("#btn-empty-ha-reenable"));

    app.openSettingsSheet("connection");
    assert.equal(document.querySelector("[data-ha-connection-status]")?.getAttribute("data-ha-connection-status"), "stop_timeout");
    document.querySelector<HTMLButtonElement>("[data-ha-stop-retry]")!.click();
    assert.equal(getHostHaLifecyclePhase(app), "disabled");
    assert.equal(document.querySelector("[data-ha-stop-retry]"), null);
    assert.equal(document.querySelector("[data-ha-connection-status]")?.getAttribute("data-ha-connection-status"), "disabled");

    useHungSnapshot = false;
    const recovered = await setHaConnectionEnabledOnHost(app, true);
    assert.equal(recovered.status, "applied");
    assert.equal(isHostHaEnabled(app), true);
    assert.equal(getHostHaLifecyclePhase(app), "enabled");
    assert.deepEqual(app.devices.map((d) => d.name), ["恢复后新灯"]);

    hungSnapshot.resolve(makeHaSnapshotPayload());
    await inFlightRefresh;
    assert.deepEqual(app.devices.map((d) => d.name), ["恢复后新灯"]);
  });

  it("keeps dual-source Xiaomi timers ready and firing when HA is disabled, and uses structured verdict codes in zh-Hant", async () => {
    const h = makeHarness();
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-dual-timer";
    app.settings.miSession = SESS_A;
    setHostDualSourceEnabled(app, true, { persist: true });
    await getHostMiAccountsStore(app).upsertAccount(SESS_A);

    await refreshDevices(app, false);
    markTimerSnapshotReady(app);
    const haStripBefore = app.devices.find((d) => d.name === "HA灯带")!;
    assert.ok(haStripBefore);

    const nowMs = 1_760_500_000_000;
    const identity = scheduledCommandIdentity(app.settings)!;
    const queue = app.scheduledCommandStore.queue(identity);
    queue.scheduledCommands = [{
      id: "t_pure_ha_paused",
      command: "关闭HA灯带",
      reply: "好",
      delaySeconds: 60,
      fireTimestampMs: nowMs + 60_000,
      intents: [{ targetId: haStripBefore.id, operation: { kind: "power", isOn: false } }],
    }];
    app.scheduledCommands = queue.scheduledCommands;
    app.scheduledCommandStore.persist();

    const dis = await setHaConnectionEnabledOnHost(app, false, { confirmPause: true, nowMs });
    assert.equal(dis.status, "applied");
    assert.equal(scheduledCommandsReady(app), true);
    const miLamp = app.devices.find((d) => d.name === "米家台灯")!;
    assert.ok(miLamp);

    assert.equal(
      enqueueScheduledCommand(app, {
        id: "t_pure_mi_due",
        command: "关闭米家台灯",
        reply: "好",
        delaySeconds: 30,
        fireTimestampMs: nowMs + 30_000,
        intents: [{ targetId: miLamp.id, operation: { kind: "power", isOn: false } }],
      }),
      true,
    );

    const miWritesBefore = h.miWritePaths.length;
    const haExecBefore = h.countCmd("ha_execute");
    processScheduledCommands(app, nowMs + 65_000);
    await new Promise((r) => setTimeout(r, 25));

    assert.equal(h.miWritePaths.length, miWritesBefore + 1);
    assert.equal(h.countCmd("ha_execute"), haExecBefore);
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.equal(queue.pausedScheduledCommands?.some((p) => p.command.id === "t_pure_ha_paused"), true);

    app.settings.interfaceLanguage = "zh-Hant";
    setLanguage("zh-Hant");
    await app.runScheduledCommand({
      id: "t_zhhant_missing",
      command: "關閉幽靈燈",
      reply: "好",
      delaySeconds: 10,
      fireTimestampMs: nowMs + 70_000,
      intents: [{ targetId: "missing_device_zhhant", operation: { kind: "power", isOn: false } }],
    });
    assert.equal(app.missedScheduledCommands.some((m) => m.id === "t_zhhant_missing"), true);
    assert.match(app.replyBanner?.text ?? "", /裝置不存在/);

    app.missedScheduledCommands = [];
    queue.missedScheduledCommands = [];
    app.scheduledCommandStore.persist();

    await app.runScheduledCommand({
      id: "t_zhhant_disabled_ha",
      command: "關閉HA燈帶",
      reply: "好",
      delaySeconds: 10,
      fireTimestampMs: nowMs + 70_000,
      intents: [{ targetId: haStripBefore.id, operation: { kind: "power", isOn: false } }],
    });
    assert.equal(app.missedScheduledCommands.length, 0);
    assert.match(app.replyBanner?.text ?? "", /Home Assistant.*已停用/);
  });

  it("prevents cachedHAHome leaks across UI views when HA is disabled, localizes gate errors on offline devices, and attributes snapshot-less raw HA entity IDs", async () => {
    const h = makeHarness();
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "ha-tok-cache-leak";

    const cachedPlug: SmartDevice = {
      id: "switch.ha_cached_plug",
      name: "缓存泄漏插座",
      roomId: "study",
      roomName: "书房",
      model: PLUG_MODEL,
      isOnline: false,
      sourceBackend: "homeAssistant",
      kind: { kind: "plug", switchEntityId: "switch.ha_cached_plug", isOn: true, powerWatts: 120, energyKwh: 3.5, childLockEntityId: null, isChildLocked: false },
    };
    const cachedSensor: SmartDevice = {
      id: "sensor.ha_cached_temp",
      name: "缓存温湿度计",
      roomId: "study",
      roomName: "书房",
      model: "miaomiaoce.sensor_ht.t2",
      isOnline: true,
      sourceBackend: "homeAssistant",
      kind: { kind: "sensor", temperature: 24.5, humidity: 52, battery: 90 },
    };
    app.settings.cachedHAHome = {
      identity: homeAssistantIdentity(HA_URL, "ha-tok-cache-leak")!,
      home: {
        devices: [cachedPlug, cachedSensor],
        rooms: [{ id: "study", name: "书房", deviceCount: 2 }],
        scenes: [{ id: "scene.ha_cached_scene", name: "缓存泄漏场景", entityId: "scene.ha_cached_scene" }],
        environmentReadings: [],
        deviceFacets: {},
      },
    };
    app.saveSettings(true);

    writeMiAccountSelectionMutation({
      storage: localStorage,
      mutate: (prev) => ({
        ...prev,
        disabledHaScopes: [HA_SCOPE],
        knownDisabledHaDevices: [],
        knownDisabledHaScenes: [],
      }),
    });
    app.devices = [];
    app.scenes = [];

    assert.equal(settingsHaCacheIfEnabled(app.settings), null);
    assert.equal(haCacheIfEnabled(app), null);

    app.openSettingsSheet("connection");
    const settingsHtml = app.root.innerHTML;
    assert.equal(settingsHtml.includes("缓存泄漏场景"), false);
    assert.equal(settingsHtml.includes("缓存泄漏插座"), false);

    syncSensorHistoryHost(app);
    tickSafetyHealthAndAutomation(app);

    const bootRoot = document.createElement("div");
    document.body.appendChild(bootRoot);
    const coldApp = new MenuMijiaWindowsApp(bootRoot);
    try {
      assert.equal(coldApp.devices.length, 0);
      assert.equal(coldApp.scenes.length, 0);
    } finally {
      coldApp.dispose();
      bootRoot.remove();
    }

    assert.equal(await app.applyCommand({ kind: "setLightPower", entityId: "light.ha_strip", isOn: true }), false);
    assert.match(app.replyBanner?.text ?? "", /Home Assistant.*已停用/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /Home Assistant is turned off/);

    assert.equal(await app.applyCommand({ kind: "activateScene", entityId: "scene.ha_movie" }), false);
    assert.match(app.replyBanner?.text ?? "", /Home Assistant.*已停用/);

    const offlineBanner =
      controlFailureUserMessage(new HaBlockedRequestError(HA_SCOPE, "ha_execute"), {
        isDeviceOnline: false,
        deviceName: cachedPlug.name,
      }) ?? "";
    assert.match(offlineBanner, /Home Assistant.*已停用/);
    assert.doesNotMatch(offlineBanner, /离线|turned off/i);
  });

  it("refuses closed HA device types before link prompts, excludes them from 全关, and rejects queued companion links with zero writes (#346 / P3b-W)", async () => {
    const h = makeHarness();
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "{{SECRET_7swvbi2f}}";
    app.settings.allowDirectURLControl = false;
    await app.refreshHADevices(false);
    const strip = app.devices.find((d) => d.name === "HA灯带")!;
    assert.ok(strip && app.allOffTargets.some((d) => d.id === strip.id));

    assert.equal(app.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS.filter((c) => c !== "light")), true);
    assert.ok(app.devices.some((d) => d.id === strip.id));
    const writesBefore = h.countCmd("ha_execute");

    await enqueueIncomingOpenUrl(app, `menumijia://power?device=${encodeURIComponent(strip.id)}&on=false`);
    assert.equal(hasPendingUrlConfirmation(app), false);
    assert.match(app.replyBanner?.text ?? "", /该设备类型已关闭/);

    assert.equal(app.allOffTargets.some((d) => d.id === strip.id), false);
    setRaycastIntegrationEnabled(app, true);
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    await enqueueIncomingOpenUrl(app, `menumijia://scene?name=allOff&token=${token}`);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /该设备类型已关闭/);
    assert.equal(h.countCmd("ha_execute"), writesBefore);

    app.devices = app.devices.filter((d) => d.id !== strip.id);
    app.haTypePruneScope = HA_SCOPE;
    app.hiddenHADevices = [{
      id: strip.id,
      name: strip.name,
      category: "light",
      connection: "home-assistant",
      sourceScope: HA_SCOPE,
      isSourceAvailable: true,
      upstreamHiddenOrDisabled: false,
      participatesInAllOff: true,
      safetySignals: [],
      readKeys: ["light.ha_strip"],
      safetyReadKeys: [],
    }];
    app.replyBanner = null;
    await enqueueIncomingOpenUrl(app, `menumijia://power?device=${encodeURIComponent(strip.id)}&on=true`);
    const readBannerText = (): string => app.replyBanner?.text ?? "";
    assert.match(readBannerText(), /该设备类型已关闭/);
    assert.equal(h.countCmd("ha_execute"), writesBefore);
  });

  it("filters a batch of closed devices without reloading capabilities for every URL all-off candidate", async (test) => {
    const h = makeHarness();
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "{{SECRET_7swvbi2f}}";
    await app.refreshHADevices(false);
    const strip = app.devices.find((d) => d.name === "HA灯带")!;
    const candidateCount = 24;
    app.devices = Array.from({ length: candidateCount }, (_, index) => ({
      ...strip,
      id: `${strip.id}-${index}`,
    }));
    assert.equal(app.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS.filter((c) => c !== "light")), true);
    await setRaycastIntegrationEnabled(app, true);
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    const readStorage = test.mock.method(localStorage, "getItem");

    await enqueueIncomingOpenUrl(app, `menumijia://scene?name=allOff&token=${token}`);
    const selectionReads = readStorage.mock.calls.filter(({ arguments: [key] }) => key === MI_ACCOUNT_CAPABILITY_STORAGE_KEY);
    assert.ok(selectionReads.length < candidateCount, `loaded capabilities ${selectionReads.length} times for ${candidateCount} candidates`);
    assert.equal(h.countCmd("ha_execute"), 0);
    assert.match(app.replyBanner?.text ?? "", /已关闭 0 台.*另有 24 台已跳过/);
  });

  it("reports all-off skips in the panel and URL replies in all supported languages", async () => {
    const h = makeHarness({
      onHaSnapshot: async () => {
        const snapshot = makeHaSnapshotPayload();
        return {
          ...snapshot,
          entities: [...snapshot.entities as unknown[], { entity_id: "fan.ha_fan", device_id: "ha-dev-heater" }],
          states: [...snapshot.states as unknown[], { entity_id: "fan.ha_fan", state: "on", attributes: { friendly_name: "HA风扇", percentage: 50 } }],
        };
      },
    });
    const { app } = h;
    app.settings.connectionMode = "homeAssistant";
    app.settings.haBaseURL = HA_URL;
    app.settings.haToken = "{{SECRET_7swvbi2f}}";
    await app.refreshHADevices(false);
    const devices = structuredClone(app.devices);
    assert.equal(app.setEnabledDeviceCategories(DEVICE_CATEGORY_IDS.filter((c) => c !== "light")), true);
    await setRaycastIntegrationEnabled(app, true);
    const token = getActiveRaycastBridgeTokenForHost(app)!;

    for (const [language, expected] of [
      ["zh-Hans", /已关闭 1 台.*另有 1 台已跳过/],
      ["zh-Hant", /已關閉 1 台.*另有 1 台已跳過/],
      ["en", /Switched off 1 devices\. Skipped 1 other devices\./],
    ] as const) {
      setLanguage(language);
      for (const source of ["panel", "url"] as const) {
        app.devices = structuredClone(devices);
        const before = h.countCmd("ha_execute");
        if (source === "panel") {
          await (app as unknown as { turnAllOff(): Promise<void> }).turnAllOff();
        } else {
          await enqueueIncomingOpenUrl(app, `menumijia://scene?name=allOff&token=${token}`);
        }
        assert.match(app.replyBanner?.text ?? "", expected, `${language} ${source}`);
        assert.equal(h.countCmd("ha_execute") - before, 1);
      }
    }
  });
});
