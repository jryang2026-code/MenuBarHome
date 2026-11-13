import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { demoDevices } from "../src/ui/demo.js";
import {
  renderMoreSettings,
  resetMoreSettingsState,
  toggleMoreSettingsExpanded,
} from "../src/ui/facetViews.js";
import { persistCredentials } from "../src/ui/appLifecycle.js";
import {
  enqueueIncomingOpenUrl,
  getActiveRaycastBridgeTokenForHost,
} from "../src/ui/speechGuard.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  MiCloudClient,
  MiCloudError,
  MiotCommandMapper,
  MiotSynthesizer,
  type HttpResponse,
  type MiSession,
  type MiotDeviceSpec,
} from "../src/core/miCloudClient.js";
import { facetControls } from "../src/core/miCloud/facets.js";
import { facetValue } from "../src/core/miotFacetText.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import {
  joinsAllOffByDefault,
  type ApplianceSpec,
  type FacetControl,
  type SmartDevice,
} from "../src/core/models.js";
import {
  SCHEDULED_COMMANDS_STORAGE_KEY,
  ScheduledCommandStore,
} from "../src/core/scheduledCommands.js";
import {
  CredentialVault,
  credentialsFromSettings,
} from "../src/core/secureStore.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing element ${selector}`);
  return found;
}

async function flushAsync(): Promise<void> {
  await setImmediate();
  await setImmediate();
  await setImmediate();
}

const TEST_SSECURITY = "AQIDBAUGBwgJCgsMDQ4PEA==";
const TEST_SESSION: MiSession = {
  userId: "10086",
  cUserId: "c10086",
  ssecurity: TEST_SSECURITY,
  serviceToken: "tok-test",
  passToken: "",
  region: "cn",
};

function jsonResponse(payload: unknown, status = 200): HttpResponse {
  return {
    status,
    headers: {},
    body: JSON.stringify(payload),
  };
}

function decryptMiRequestData(body: string): Record<string, unknown> {
  const params = new URLSearchParams(body);
  const nonce = params.get("_nonce") ?? "";
  const encrypted = params.get("data") ?? "";
  const signed = MiCloudCrypto.signedNonce(TEST_SSECURITY, nonce);
  return JSON.parse(MiCloudCrypto.decryptResponse(encrypted, signed)) as Record<string, unknown>;
}

beforeEach(() => {
  dom = mountTestWindow({ stubInterval: true });
  installCssEscape();
  resetMoreSettingsState();
  setLanguage("zh-Hans");
  localStorage.setItem(
    "menumijia.windows.update.v1",
    JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }),
  );
});

afterEach(async () => {
  setLanguage("zh-Hans");
  resetMoreSettingsState();
  await closeTestWindow(dom);
});

describe("Release audit fixes — Core & MIoT parity", () => {
  it("F35: ScheduledCommandStore salvages valid timers when a sibling entry is corrupt and backs up unreadable raw JSON", () => {
    const validCmd = {
      id: "timer-ok",
      command: "10分钟后关灯",
      reply: "好的，10 分钟后关闭客厅吸顶灯",
      delaySeconds: 600,
      fireTimestampMs: Date.now() + 600_000,
      intents: [{ targetId: "light-1", operation: { kind: "power", isOn: false } }],
    };
    const corruptPayload = JSON.stringify({
      version: 1,
      sources: [
        {
          identity: "demo",
          scheduledCommands: [validCmd, { id: "broken-timer", fireTimestampMs: "not-a-number" }],
          missedScheduledCommands: [],
        },
        { identity: "", scheduledCommands: [] },
      ],
    });
    localStorage.setItem(SCHEDULED_COMMANDS_STORAGE_KEY, corruptPayload);

    const store = new ScheduledCommandStore(localStorage);
    const demoQueue = store.queue("demo");
    assert.equal(demoQueue.scheduledCommands.length, 1);
    assert.equal(demoQueue.scheduledCommands[0]?.id, "timer-ok");

    assert.equal(store.persist(), true);
    assert.equal(
      localStorage.getItem(`${SCHEDULED_COMMANDS_STORAGE_KEY}.unreadable`),
      corruptPayload,
      "corrupt original payload is still preserved in .unreadable backup",
    );
  });

  it("F38: renderMoreSettings preserves exact decimal range step (0.05 / 0.01) instead of rounding to 1 decimal", () => {
    const controls: FacetControl[] = [
      {
        id: "2.1",
        kind: "slider",
        name: "water-level",
        title: "水位微调",
        serviceName: "fish-tank",
        unit: null,
        scale: null,
        value: 0.25,
        options: [],
        range: { min: 0, max: 1, step: 0.05 },
        isWritable: true,
        writesByDefault: true,
        isHighValue: true,
        target: { kind: "property", entityId: "miot:dev1:2", piid: 1 },
      },
      {
        id: "2.2",
        kind: "slider",
        name: "gain",
        title: "精细增益",
        serviceName: "fish-tank",
        unit: null,
        scale: null,
        value: 0.03,
        options: [],
        range: { min: 0, max: 0.5, step: 0.01 },
        isWritable: true,
        writesByDefault: true,
        isHighValue: true,
        target: { kind: "property", entityId: "miot:dev1:2", piid: 2 },
      },
    ];
    toggleMoreSettingsExpanded("dev1");
    const html = renderMoreSettings({
      deviceId: "dev1",
      facets: controls,
      allowAdvanced: false,
      escapeHtml: (s) => s,
    });
    assert.match(html, /step="0\.05"\s+value="0\.25"/);
    assert.match(html, /step="0\.01"\s+value="0\.03"/);
  });

  it("P4: joinsAllOffByDefault includes HA humidifier.* appliance cards and excludes other appliances", () => {
    const baseAppliance: ApplianceSpec = {
      kind: "appliance",
      entityId: "humidifier.bedroom",
      isOn: true,
      powerPresent: true,
      powerWritable: true,
      currentMode: null,
      availableModes: [],
      modeWritable: false,
      targetTemperature: null,
      currentTemperature: null,
      minTemp: 30,
      maxTemp: 80,
      step: 1,
      temperatureWritable: false,
      statusText: null,
      faultText: null,
      remainingMinutes: null,
      startAction: null,
      pauseAction: null,
      stopAction: null,
      powerEntityId: "humidifier.bedroom",
      modeEntityId: "humidifier.bedroom",
      temperatureEntityId: "humidifier.bedroom",
      light: null,
      fanLevel: null,
      currentHumidity: 55,
      symbolName: "humidity.fill",
      roomReading: false,
      heats: false,
    };
    const haHumidifier: SmartDevice = {
      id: "humidifier.bedroom",
      name: "卧室加湿器",
      roomId: "bedroom",
      roomName: "主卧",
      model: "ha.humidifier",
      isOnline: true,
      kind: baseAppliance,
    };
    const waterHeater: SmartDevice = {
      ...haHumidifier,
      id: "miot:heater",
      kind: {
        ...baseAppliance,
        entityId: "miot:heater:2",
        powerEntityId: "miot:heater:2",
        heats: true,
      },
    };
    assert.equal(joinsAllOffByDefault(haHumidifier), true);
    assert.equal(joinsAllOffByDefault(waterHeater), false);
  });

  it("P6: MiotSynthesizer, facetControls, and facetValue parse numeric/boolean strings ('1', '0', '26.5', 'true')", () => {
    const acSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:air-conditioner:0000A004:test-ac:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-conditioner:0000780F:test-ac:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-ac:1", format: "bool", access: ["read", "write"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:mode:00000008:test-ac:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [{ value: 1, description: "Cool" }],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:target-temperature:00000021:test-ac:1",
              format: "float",
              access: ["read", "write"],
              valueRange: [16, 31, 0.5],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:test-ac:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:test-ac:1", format: "float", access: ["read"] },
            { iid: 2, type: "urn:miot-spec-v2:property:pm2.5-density:00000034:test-ac:1", format: "float", access: ["read"] },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:indicator-light:00007803:test-ac:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-ac:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
      ],
    };
    const values = new Map<string, unknown>([
      ["ac1.2.1", "1"],
      ["ac1.2.2", "1"],
      ["ac1.2.3", "26.5"],
      ["ac1.3.1", "24.5"],
      ["ac1.3.2", "18"],
      ["ac1.4.1", "true"],
    ]);
    const synthesized = MiotSynthesizer.synthesize(
      [{ did: "ac1", name: "客厅空调", model: "xiaomi.aircondition.c1", isOnline: true, specType: acSpec.type }],
      [],
      { "xiaomi.aircondition.c1": acSpec },
      values,
    );
    const [device] = synthesized.devices;
    assert.ok(device && device.kind.kind === "climate");
    assert.equal(device.kind.hvacMode, "cool");
    assert.equal(device.kind.targetTemperature, 26.5);
    assert.equal(device.kind.currentTemperature, 24.5);

    const facets = facetControls(acSpec, "ac1", values, 2, new Set(["2.1", "2.2", "2.3", "3.1"]));
    const ledFacet = facets.find((f) => f.serviceName === "indicator-light");
    assert.ok(ledFacet);
    assert.equal(ledFacet.value, true);
    assert.equal(facetValue({ ...ledFacet, value: "1" }), "开");
    assert.equal(facetValue({ ...ledFacet, value: "0" }), "关");
  });

  it("P9: MiCloudClient maps non-zero API bodies with invalid_token / unauthorized to sessionExpired", async () => {
    for (const errMsg of ["invalid_token", "Unauthorized access"]) {
      const client = new MiCloudClient(TEST_SESSION, async () =>
        jsonResponse({ code: -401, message: errMsg }),
      );
      await assert.rejects(
        () => client.deviceList(),
        (err: unknown) => err instanceof MiCloudError && err.kind === "sessionExpired",
      );
    }
  });

  it("P10: MiotCommandMapper rounds float steps cleanly, coerces bool<->uint8, and skips listless climate mode", () => {
    const spec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:air-conditioner:0000A004:test-p10:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-conditioner:0000780F:test-p10:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-p10:1", format: "uint8", access: ["read", "write"] },
            { iid: 2, type: "urn:miot-spec-v2:property:mode:00000008:test-p10:1", format: "uint8", access: ["read", "write"] },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:target-temperature:00000021:test-p10:1",
              format: "float",
              access: ["read", "write"],
              valueRange: [0, 1, 0.1],
            },
            { iid: 4, type: "urn:miot-spec-v2:property:eco:00000024:test-p10:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:toggle-eco:00002800:test-p10:1", in: [1, 4] },
          ],
        },
      ],
    };

    const modeWrite = MiotCommandMapper.map(
      { kind: "setClimateMode", entityId: "miot:ac1:2", hvacMode: "cool" },
      spec,
    );
    assert.equal(modeWrite.kind, "setProps");
    assert.deepEqual(modeWrite.writes, [{ did: "ac1", siid: 2, piid: 1, value: 1 }]);

    const tempWrite = MiotCommandMapper.map(
      { kind: "setClimateTemperature", entityId: "miot:ac1:2", temperature: 0.3 },
      spec,
    );
    assert.equal(tempWrite.kind, "setProps");
    assert.equal(tempWrite.writes[0]?.value, 0.3);

    const boolPropWrite = MiotCommandMapper.map(
      { kind: "setMiotProperty", entityId: "miot:ac1:2", piid: 4, value: 1 },
      spec,
    );
    assert.equal(boolPropWrite.kind, "setProps");
    assert.equal(boolPropWrite.writes[0]?.value, true);

    const actionCoercedOn = MiotCommandMapper.map(
      { kind: "pressButton", entityId: "miot-action:ac1:2:1", arguments: [true, 1] },
      spec,
    );
    assert.equal(actionCoercedOn.kind, "action");
    assert.deepEqual(actionCoercedOn.call.inputs, [1, true]);

    const actionCoercedOff = MiotCommandMapper.map(
      { kind: "pressButton", entityId: "miot-action:ac1:2:1", arguments: [false, 0] },
      spec,
    );
    assert.equal(actionCoercedOff.kind, "action");
    assert.deepEqual(actionCoercedOff.call.inputs, [0, false]);
  });

  it("5-1: credentialsFromSettings preserves custom slot key across different custom endpoints and CredentialVault serializes concurrent persists", async () => {
    const snap = credentialsFromSettings(
      {
        assistantBaseURL: "https://second-custom.example.com/v1",
        assistantCustomKeyEndpoint: "https://first-custom.example.com/v1",
        openRouterApiKey: "",
      },
      {
        custom: "sk-custom-first",
        openai: "sk-openai",
      },
    );
    assert.equal(snap.assistantApiKeys?.custom, "sk-custom-first");
    assert.equal(snap.assistantApiKeys?.openai, "sk-openai");

    const store = new Map<string, string>();
    const order: string[] = [];
    let releaseFirstSet!: () => void;
    const firstSetBlocked = new Promise<void>((resolve) => {
      releaseFirstSet = resolve;
    });
    let blockedOnce = false;
    const vault = new CredentialVault(async <T>(cmd: string, args: Record<string, unknown>): Promise<T | null> => {
      const name = String(args.name ?? "");
      if (cmd === "secure_store_set") {
        order.push(`start:${name}:${String(args.value)}`);
        if (!blockedOnce && name === "ha_token") {
          blockedOnce = true;
          await firstSetBlocked;
        }
        store.set(name, String(args.value));
        order.push(`end:${name}:${String(args.value)}`);
      } else if (cmd === "secure_store_delete") {
        store.delete(name);
      } else if (cmd === "secure_store_get") {
        return (store.get(name) ?? null) as T | null;
      }
      return null;
    });

    const p1 = vault.persist({ miSession: null, haToken: "tok-1", assistantApiKey: "", assistantApiKeys: {} });
    const p2 = vault.persist({ miSession: null, haToken: "tok-2", assistantApiKey: "", assistantApiKeys: {} });
    await flushAsync();
    assert.deepEqual(order, ["start:ha_token:tok-1"], "second persist waits behind in-flight first persist");
    releaseFirstSet();
    await Promise.all([p1, p2]);
    assert.equal(store.get("ha_token"), "tok-2");
  });
});

describe("Release audit fixes — UI, cloud refresh, camera & localization", () => {
  it("F31: voice input aborts cleanly on second mic click and ignores transcripts across source switches", async () => {
    let lastInstance: {
      aborted: boolean;
      stopped: boolean;
      onresult: ((ev: unknown) => void) | null;
      onend: (() => void) | null;
    } | null = null;

    class FakeSpeechRecognition {
      lang = "";
      interimResults = false;
      continuous = false;
      aborted = false;
      stopped = false;
      onresult: ((ev: unknown) => void) | null = null;
      onerror: (() => void) | null = null;
      onend: (() => void) | null = null;
      constructor() {
        lastInstance = this;
      }
      start(): void {}
      abort(): void {
        this.aborted = true;
      }
      stop(): void {
        this.stopped = true;
      }
    }
    (window as unknown as Record<string, unknown>).SpeechRecognition = FakeSpeechRecognition;

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const handled: string[] = [];
    app.handleNaturalCommand = async (text: string) => {
      handled.push(text);
    };

    app.toggleVoiceInput();
    assert.equal(app.isListeningVoice, true);
    const firstRec = lastInstance!;
    app.toggleVoiceInput();
    assert.equal(app.isListeningVoice, false);
    assert.equal(firstRec.aborted, true);
    firstRec.onresult?.({ results: [[{ transcript: "关灯" }]] });
    assert.deepEqual(handled, []);

    app.toggleVoiceInput();
    const secondRec = lastInstance!;
    app.invalidateSourceControl();
    secondRec.onresult?.({ results: [[{ transcript: "打开客厅灯" }]] });
    assert.deepEqual(handled, []);
  });

  it("F32 & F33: transient homeRooms failure preserves cached homes, and selectHome invalidates stale in-flight refresh", async () => {
    const lightSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:light:0000A001:test-f32:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:test-f32:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-f32:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
      ],
    };

    let failHomeRoom = false;
    const pollControl: { release?: () => void } = {};
    let blockNextPropGet = false;

    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd === "secure_store_get") {
            if (args.name === "mi_session") return JSON.stringify(TEST_SESSION);
            return null;
          }
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("/instance?")) {
            return jsonResponse(lightSpec);
          }
          const body = String(args.body ?? "");
          if (url.includes("device_list")) {
            return jsonResponse({
              code: 0,
              result: {
                list: [
                  { did: "dev-a", name: "A家灯", model: "yeelink.light.a", isOnline: true, spec_type: lightSpec.type },
                  { did: "dev-b", name: "B家灯", model: "yeelink.light.b", isOnline: true, spec_type: lightSpec.type },
                ],
              },
            });
          }
          if (url.includes("homeroom/gethome")) {
            if (failHomeRoom) {
              return { status: 502, headers: {}, body: "bad gateway" };
            }
            return jsonResponse({
              code: 0,
              result: {
                homelist: [
                  { id: "home-a", name: "北京家", roomlist: [{ id: "r-a", name: "客厅", dids: ["dev-a"] }] },
                  { id: "home-b", name: "上海家", roomlist: [{ id: "r-b", name: "主卧", dids: ["dev-b"] }] },
                ],
              },
            });
          }
          if (url.includes("miotspec/prop/get")) {
            const reqData = decryptMiRequestData(body);
            const params = (reqData.params as Array<{ did: string; siid: number; piid: number }>) ?? [];
            if (blockNextPropGet && params.some((p) => p.did === "dev-a")) {
              blockNextPropGet = false;
              await new Promise<void>((resolve) => {
                pollControl.release = resolve;
              });
            }
            return jsonResponse({
              code: 0,
              result: params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: true })),
            });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        selectedHomeId: "home-a",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();
    await flushAsync();
    assert.equal(app.homes.length, 2);
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);

    // F32: transient homeroom failure must NOT wipe app.homes or leak home-b devices into home-a.
    failHomeRoom = true;
    await app.refreshDevices(true);
    assert.equal(app.homes.length, 2, "cached homes survive transient homeroom HTTP error");
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-a"]);
    failHomeRoom = false;

    // F33: start an in-flight refresh on home-a, then switch to home-b before home-a finishes.
    blockNextPropGet = true;
    const staleRefresh = app.refreshDevices(true);
    await flushAsync();
    assert.ok(pollControl.release, "home-a property poll is paused in flight");

    app.selectHome("home-b");
    await flushAsync();
    await flushAsync();
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-b"], "home-b refresh succeeded immediately");

    // Let the stale home-a refresh finish; it must not overwrite home-b's devices.
    pollControl.release();
    await staleRefresh;
    await flushAsync();
    assert.equal(app.settings.selectedHomeId, "home-b");
    assert.deepEqual(app.devices.map((d) => d.id), ["dev-b"]);
  });

  it("F34: switching data source while QR login awaits scan prevents flipping back to xiaomiCloud", async () => {
    const scanGate: { release?: () => void } = {};
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("longPolling/loginUrl")) {
            return jsonResponse({
              qr: "https://account.xiaomi.com/qr.png",
              loginUrl: "https://account.xiaomi.com/login",
              lp: "https://lp.account.xiaomi.com/poll",
              timeout: 60,
            });
          }
          if (url === "https://lp.account.xiaomi.com/poll") {
            await new Promise<void>((resolve) => {
              scanGate.release = resolve;
            });
            return jsonResponse({
              userId: "10086",
              cUserId: "c10086",
              ssecurity: TEST_SSECURITY,
              passToken: "pass",
              location: "https://sts.api.io.mi.com/sts?ticket=1",
            });
          }
          if (url.startsWith("https://sts.api.io.mi.com/sts")) {
            return {
              status: 200,
              headers: { "set-cookie": "serviceToken=tok-new; Path=/" },
              body: "",
            };
          }
          return jsonResponse({});
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();

    const qrPromise = app.startXiaomiQRLogin();
    await flushAsync();
    assert.ok(scanGate.release, "QR login is awaiting scan");

    app.invalidateSourceControl();
    app.settings.connectionMode = "homeAssistant";
    scanGate.release();
    await qrPromise;
    await flushAsync();

    assert.equal(app.settings.connectionMode, "homeAssistant");
    assert.equal(app.settings.miSession, null);
  });

  it("F36 & 5-2: resolveHaCameraStreamUrl avoids /api/api/ duplication and closing a removed live camera still releases P2P", async () => {
    const cameraSpec: MiotDeviceSpec = {
      type: "urn:miot-spec-v2:device:camera:0000A01C:test-cam:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:test-cam:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test-cam:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:stream-p2p:00007881:test-cam:1",
          properties: [],
          actions: [{ iid: 2, type: "urn:miot-spec-v2:action:stop-stream:00002822:test-cam:1" }],
        },
      ],
    };

    let stopStreamActionCalls = 0;
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          if (cmd !== "native_http") return null;
          const url = String(args.url ?? "");
          if (url.includes("/instances?")) {
            return jsonResponse({
              instances: [{ model: "isa.camera.hlc7", type: cameraSpec.type }],
            });
          }
          if (url.includes("/instance?")) {
            return jsonResponse(cameraSpec);
          }
          if (url.includes("miotspec/action")) {
            stopStreamActionCalls += 1;
            return jsonResponse({ code: 0, result: { code: 0 } });
          }
          return jsonResponse({ code: 0, result: {} });
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "homeAssistant",
        hasCompletedOnboarding: true,
        haBaseURL: "http://ha.local:8123/api/",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const haCam: SmartDevice = {
      id: "camera.front_door",
      name: "门口摄像机",
      roomId: "hallway",
      roomName: "玄关",
      model: "ha.camera",
      isOnline: true,
      kind: {
        kind: "camera",
        entityId: "camera.front_door",
        isOn: true,
        powerWritable: false,
        availableNightShots: [],
        motionDetectionEntityId: null,
        isMotionDetectionOn: null,
        nightShot: null,
        streamEntityId: "camera.front_door",
        snapshotPath: "/api/camera_proxy/camera.front_door?token=abc",
      },
    };
    assert.equal(
      app.cameraLive.resolveHaCameraStreamUrl(haCam),
      "http://ha.local:8123/api/camera_proxy_stream/camera.front_door?token=abc",
    );

    // 5-2: Open a Xiaomi camera, remove it from app.devices, then close — stop-stream still fires!
    app.settings.connectionMode = "xiaomiCloud";
    app.settings.miSession = TEST_SESSION;
    const miCam: SmartDevice = {
      id: "cam-mi-1",
      name: "客厅摄像机",
      roomId: "living",
      roomName: "客厅",
      model: "isa.camera.hlc7",
      isOnline: true,
      kind: {
        kind: "camera",
        entityId: "miot:cam-mi-1:2",
        isOn: false,
        powerWritable: true,
        availableNightShots: [],
        motionDetectionEntityId: null,
        isMotionDetectionOn: null,
        nightShot: null,
        streamEntityId: null,
        snapshotPath: null,
      },
    };
    app.devices = [miCam];
    app.cameraLive.openCameraLiveView("cam-mi-1");
    assert.equal(app.cameraLive.activeLiveCameraId, "cam-mi-1");

    app.devices = [];
    app.cameraLive.closeCameraLiveView();
    await flushAsync();
    await flushAsync();
    assert.equal(app.cameraLive.activeLiveCameraId, null);
    assert.equal(stopStreamActionCalls, 1, "stop-stream action still sent using cached camera snapshot");
  });

  it("F37: Fahrenheit climate slider clamps converted Celsius within [minTemp, maxTemp]", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        temperatureUnit: "fahrenheit",
        useClimateControlBar: false,
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const ac = app.devices.find((d) => d.kind.kind === "climate")!;
    assert.ok(ac && ac.kind.kind === "climate");
    // Set minTemp=18°C (64.4°F -> slider min 64°F, which converts to 17.78°C without clamping).
    ac.kind = { ...ac.kind, minTemp: 18, maxTemp: 31, hvacMode: "cool", targetTemperature: 24 };
    app.layout.tileSizes[ac.id] = "half";
    app.expandedDeviceId = ac.id;
    app.render();

    let capturedTemp: number | null = null;
    app.executeSingleCommand = async (_dev, command) => {
      if (command.kind === "setClimateTemperature") {
        capturedTemp = command.temperature;
      }
    };

    const slider = element(`[data-actemp="${ac.id}"]`) as HTMLInputElement;
    assert.equal(slider.min, "64");
    slider.value = "64";
    slider.dispatchEvent(new Event("change", { bubbles: true }));
    await flushAsync();
    assert.equal(capturedTemp, 18, "64°F endpoint clamps to minTemp 18°C instead of 17.78°C");
  });

  it("P11 & C5: '/' focuses command input, '2' switches room pill, and English demo/settings have no untranslated Chinese or double-t()", async () => {
    setLanguage("en");
    const enDemo = demoDevices();
    assert.ok(enDemo.some((d) => d.name === "Living Room Camera"));
    assert.ok(enDemo.every((d) => !/[\u4e00-\u9fff]/.test(d.roomName ?? "")));
    assert.ok(enDemo.every((d) => !/[\u4e00-\u9fff]/.test(d.name)));

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "en",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.isShowingAssistantBar = false;
    app.render();

    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "/", bubbles: true }));
    assert.equal(app.isShowingAssistantBar, true);
    assert.equal(document.activeElement?.id, "command-input");

    (document.activeElement as HTMLElement | null)?.blur();
    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "2", bubbles: true }));
    assert.equal(app.listCut.kind, "room");

    app.openSettingsSheet("connection");
    const sheetText = element(".cc-sheet").textContent ?? "";
    assert.match(sheetText, /Real devices via Mi Cloud/);
    assert.match(sheetText, /Demo devices/);
  });

  it("5-1: persistCredentials called while hydrateCredentials is awaiting vault.load does not clobber unhydrated preset keys", async () => {
    const vaultStore = new Map<string, string>([
      ["assistant_api_key_openai", "sk-saved-openai"],
    ]);
    const loadGate: { release?: () => void } = {};
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
          const name = String(args.name ?? "");
          if (cmd === "secure_store_get") {
            if (name === "assistant_api_key_openai" && !loadGate.release) {
              await new Promise<void>((resolve) => {
                loadGate.release = resolve;
              });
            }
            return vaultStore.get(name) ?? null;
          }
          if (cmd === "secure_store_set") {
            vaultStore.set(name, String(args.value ?? ""));
          } else if (cmd === "secure_store_delete") {
            vaultStore.delete(name);
          }
          return null;
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        assistantBaseURL: "https://openrouter.ai/api/v1",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();
    assert.ok(loadGate.release, "hydrateCredentials is suspended in vault.load");

    // Triggering persistCredentials mid-hydration must defer rather than delete assistant_api_key_openai.
    app.settings.haToken = "ha-tok-early";
    await persistCredentials(app);
    loadGate.release();
    await flushAsync();
    await flushAsync();

    assert.equal(vaultStore.get("assistant_api_key_openai"), "sk-saved-openai");
    assert.equal(vaultStore.get("ha_token"), "ha-tok-early");
  });

  it("S1 (#21): external high-risk URL renders imperative prompt with localized '?', clears search/camera overlays, scrolls [data-tile-id], and renders confirm row on primary-empty half-width climate with facets", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (cmd: string) => {
          if (cmd === "is_workstation_locked") return false;
          if (cmd === "drain_pending_open_urls") return [];
          return null;
        },
      },
    });

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "en",
        enableRaycastIntegration: true,
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    await flushAsync();
    const token = getActiveRaycastBridgeTokenForHost(app)!;
    assert.ok(token, "raycast bridge token initialized");

    const plug = app.devices.find((d) => d.kind.kind === "plug" && d.isOnline)!;
    const cam = app.devices.find((d) => d.kind.kind === "camera")!;
    assert.ok(plug && cam);
    if (plug.kind.kind === "plug") {
      plug.kind = { ...plug.kind, isOn: false };
    }

    // Set up obstructing overlays: active live camera + non-matching search query + input value.
    app.cameraLive.openCameraLiveView(cam.id);
    assert.equal(app.cameraLive.activeLiveCameraId, cam.id);
    app.panelSearch.query = "nonexistent-filter";
    app.render();
    const searchInput = document.querySelector<HTMLInputElement>("#command-input");
    if (searchInput) searchInput.value = "nonexistent-filter";

    const scrolledTileIds: string[] = [];
    const origScroll = window.HTMLElement.prototype.scrollIntoView;
    window.HTMLElement.prototype.scrollIntoView = function scrollSpy(this: HTMLElement): void {
      const tileId = this.getAttribute("data-tile-id");
      if (tileId) scrolledTileIds.push(tileId);
    };

    try {
      await enqueueIncomingOpenUrl(
        app,
        `menumijia://power?device=${encodeURIComponent(plug.id)}&on=true&token=${token}`,
      );
      await flushAsync();

      assert.equal(app.cameraLive.activeLiveCameraId, null, "camera live overlay closed");
      assert.equal(app.panelSearch.query, "", "search filter cleared");
      assert.equal(
        document.querySelector<HTMLInputElement>("#command-input")?.value ?? "",
        "",
        "search input value cleared",
      );
      assert.ok(scrolledTileIds.includes(plug.id), "scrollIntoView hit [data-tile-id]");

      const confirmBtn = element(`[data-high-risk-confirm="${plug.id}"]`);
      const promptLabelText = confirmBtn.parentElement?.querySelector("span")?.textContent?.trim() ?? "";
      assert.equal(
        promptLabelText,
        `Turn on ${plug.name}?`,
        "high-risk prompt uses imperative verb and ASCII question mark in English",
      );
      assert.doesNotMatch(promptLabelText, /Turned on|？/);

      // Half-width heater (`climate`) with empty primary drawer + facets still renders confirm button!
      const heater: SmartDevice = {
        id: "climate.FacetOnlyHeater",
        name: "Bedroom Heater",
        roomId: "bedroom",
        roomName: "Bedroom",
        model: "zhimi.heater.zb1",
        isOnline: true,
        kind: {
          kind: "climate",
          entityId: "climate.FacetOnlyHeater",
          isOn: false,
          powerWritable: true,
          hvacMode: "off",
          availableModes: [],
          currentTemperature: 21,
          targetTemperature: 21,
          temperatureWritable: false,
          minTemp: 18,
          maxTemp: 28,
          step: 1,
          fanMode: null,
          availableFanModes: [],
          swingMode: null,
          availableSwingModes: [],
        },
      };
      const childLockFacet: FacetControl = {
        id: "3.1",
        kind: "toggle",
        name: "physical-controls-locked",
        title: "Child Lock",
        serviceName: "physical-controls-locked",
        unit: null,
        scale: null,
        value: false,
        options: [],
        range: null,
        isWritable: true,
        writesByDefault: true,
        isHighValue: false,
        target: { kind: "property", entityId: "miot:heater:3", piid: 1 },
      };
      app.devices.push(heater);
      app.deviceFacets = { ...app.deviceFacets, [heater.id]: [childLockFacet] };
      app.layout.tileSizes[heater.id] = "half";
      app.render();

      await enqueueIncomingOpenUrl(
        app,
        `menumijia://power?device=${encodeURIComponent(heater.id)}&on=true&token=${token}`,
      );
      await flushAsync();

      assert.equal(app.expandedDeviceId, heater.id);
      const heaterConfirm = element(`[data-high-risk-confirm="${heater.id}"]`);
      const heaterPrompt = heaterConfirm.parentElement?.querySelector("span")?.textContent?.trim() ?? "";
      assert.equal(heaterPrompt, "Turn on Bedroom Heater?");
    } finally {
      window.HTMLElement.prototype.scrollIntoView = origScroll;
    }
  });

  it("C5 (#21): English toggle, high-risk, cover, and fan oscillation strings have proper spacing and zero Chinese leakage", async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "en",
      }),
    );
    const app = new MenuMijiaWindowsApp(element("#app"));
    const light = app.devices.find((d) => d.kind.kind === "light" && d.isOnline)!;
    const plug = app.devices.find((d) => d.kind.kind === "plug" && d.isOnline)!;
    const fan = app.devices.find((d) => d.kind.kind === "fan" && d.isOnline)!;
    assert.ok(light && plug && fan);

    // 1) Low-risk light toggle summary in English ("Turned on/off <name>", never "已Turn...")
    element(`[data-toggle-device="${light.id}"]`).click();
    await flushAsync();
    assert.ok(app.replyBanner, "replyBanner populated after light toggle");
    assert.match(app.replyBanner.text, /^Turned (on|off) /);
    assert.doesNotMatch(app.replyBanner.text, /[\u4e00-\u9fff]/);

    // 2) High-risk plug first tap (when off -> turning on) confirmation prompt has space ("Turn on <name>")
    if (plug.kind.kind === "plug") {
      plug.kind = { ...plug.kind, isOn: false };
    }
    app.render();
    element(`[data-toggle-device="${plug.id}"]`).click();
    await flushAsync();
    assert.ok(app.replyBanner);
    assert.match(app.replyBanner.text, /Turn on /);
    assert.doesNotMatch(app.replyBanner.text, /[\u4e00-\u9fff]/);

    // 3) Fan oscillation button renders "Oscillation on" / "Oscillation off" (no "摇头")
    if (fan.kind.kind === "fan") {
      fan.kind = { ...fan.kind, isOn: true, isOscillating: true, swingWritable: true };
    }
    app.expandedDeviceId = fan.id;
    app.render();
    const oscBtnOn = element(`[data-fanosc="${fan.id}"]`);
    assert.equal(oscBtnOn.textContent?.trim(), "Oscillation on");
    if (fan.kind.kind === "fan") {
      fan.kind = { ...fan.kind, isOscillating: false };
    }
    app.render();
    const oscBtnOff = element(`[data-fanosc="${fan.id}"]`);
    assert.equal(oscBtnOff.textContent?.trim(), "Oscillation off");

    // 4) Cover motor open/close: curtain summary & garage-door high-risk prompt in English
    const curtain: SmartDevice = {
      id: "cover.en_curtain",
      name: "Bedroom Curtain",
      roomId: "bedroom",
      roomName: "Bedroom",
      model: "lumi.curtain.v1",
      isOnline: true,
      kind: {
        kind: "cover",
        subtype: "curtain",
        entityId: "cover.en_curtain",
        positionPercent: 0,
        positionWritable: true,
        openDescription: "Open",
        closeDescription: "Close",
        pauseDescription: "Stop",
        batteryPercent: null,
        faultText: null,
        motion: "stopped",
      },
    };
    const garage: SmartDevice = {
      id: "cover.en_garage",
      name: "Main Garage Door",
      roomId: "garage",
      roomName: "Garage",
      model: "ha.garage",
      isOnline: true,
      kind: {
        kind: "cover",
        subtype: "garage-door",
        entityId: "cover.en_garage",
        positionPercent: 0,
        positionWritable: false,
        openDescription: "Open",
        closeDescription: "Close",
        pauseDescription: null,
        batteryPercent: null,
        faultText: null,
        motion: "stopped",
      },
    };
    app.devices.push(curtain, garage);
    app.expandedDeviceId = curtain.id;
    app.render();
    element(`[data-covermotor="${curtain.id}|open|Open"]`).click();
    await flushAsync();
    assert.equal(app.replyBanner?.text, "Turned on Bedroom Curtain");

    app.expandedDeviceId = garage.id;
    app.render();
    element(`[data-covermotor="${garage.id}|open|Open"]`).click();
    await flushAsync();
    assert.match(app.replyBanner?.text ?? "", /Open Main Garage Door/);
    assert.doesNotMatch(app.replyBanner?.text ?? "", /[\u4e00-\u9fff]/);
  });
});
