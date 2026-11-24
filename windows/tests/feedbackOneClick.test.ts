import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  FeedbackBackendOption,
  FeedbackDiagnosticsBuilder,
  countFeedbackBackendDevices,
  feedbackSignals,
  type FeedbackDiagnosticsInput,
} from "../src/core/diagnosticsAndScanner.js";
import type { SmartDevice } from "../src/core/models.js";

/**
 * #29: the one-click feedback link prefills a GitHub issue with a block that cannot name a person,
 * a device or a secret, and it stays short enough for a browser to carry whole.
 */
// The JWT is assembled from its parts so the repository's secret scan does not read a fixture as a
// leaked credential.
const POISON = [
  ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiI3MDAxMjM0NTYifQ", "c2lnbmF0dXJl"].join("."),
  "Bearer abcdefghijklmnop",
  "sk-abcdefghijklmnop",
  "ghp_abcdefghijklmnopqrst",
  "http://192.168.1.60:8123",
  "192.168.1.60",
  "AA:BB:CC:DD:EE:FF",
  "zhangsan@example.com",
  "miot:123456789:2",
  "700123456",
];

function poisonedInput(): FeedbackDiagnosticsInput {
  return {
    appVersion: `1.5.0 ${POISON.join(" ")}`,
    osVersion: `Windows 10/11 ${POISON.join(" ")}`,
    platform: "Windows",
    backends: [
      { label: `米家云端直连 ${POISON.join(" ")}`, deviceCount: 12, onlineDeviceCount: 9 },
      { label: "Home Assistant", deviceCount: 4, onlineDeviceCount: 4 },
    ],
    signals: [
      { code: "MI_AUTH", count: 3 },
      { code: "LAN_COOLDOWN", count: 2 },
    ],
    backendOption: FeedbackBackendOption.dual,
  };
}

function decodeQuery(url: string): string {
  return decodeURIComponent(url.slice(url.indexOf("?") + 1));
}

describe("one-click feedback link (#29)", () => {
  it("carries no secret, identifier, IP, MAC or contact from the diagnostics source", () => {
    const input = poisonedInput();
    const block = FeedbackDiagnosticsBuilder.block(input);
    const url = FeedbackDiagnosticsBuilder.issueURL(input);
    assert.ok(url, "a URL is always built");
    const decoded = decodeQuery(url);

    for (const secret of POISON) {
      assert.ok(!block.includes(secret), `block leaked ${secret}`);
      assert.ok(!url.includes(secret), `URL leaked ${secret}`);
      assert.ok(!decoded.includes(secret), `prefilled query leaked ${secret}`);
    }
    assert.ok(block.includes("1.5.0"));
    assert.ok(block.includes("MI_AUTHx3"));
  });

  it("prefills the bug form's fields", () => {
    const input: FeedbackDiagnosticsInput = {
      appVersion: "1.5.0",
      osVersion: "Windows 10/11",
      platform: "Windows",
      backends: [{ label: "米家云端直连", deviceCount: 7, onlineDeviceCount: 6 }],
      signals: [{ code: "MI_CLOUD", count: 2 }],
      backendOption: FeedbackBackendOption.mi,
    };
    const url = FeedbackDiagnosticsBuilder.issueURL(input);
    assert.ok(url);
    const params = new URL(url).searchParams;

    assert.ok(url.startsWith("https://github.com/jryang2026-code/MenuBarHome/issues/new?"));
    assert.equal(params.get("template"), "bug_report.yml");
    assert.equal(params.get("platform"), "Windows");
    assert.equal(params.get("app-version"), "1.5.0");
    assert.equal(params.get("os-version"), "Windows 10/11");
    assert.equal(params.get("backend"), FeedbackBackendOption.mi);
    assert.match(params.get("title") ?? "", /1\.5\.0/);
    const block = params.get("diagnostics") ?? "";
    assert.ok(block.includes("1.5.0"));
    assert.ok(block.includes("米家云端直连"));
    assert.ok(block.includes("MI_CLOUDx2"));
  });

  it("escapes a plus sign so it survives the form decode", () => {
    const url = FeedbackDiagnosticsBuilder.issueURL({
      appVersion: "1.5.0+build",
      osVersion: "Windows 10/11",
      platform: "Windows",
    });
    assert.ok(url);
    assert.ok(url.includes("%2B"));
    assert.equal(new URL(url).searchParams.get("app-version"), "1.5.0+build");
  });

  it("truncates an oversized block instead of shipping a link a browser would cut", () => {
    const backends = Array.from({ length: 400 }, (_, index) => ({
      label: `数据源${index}名称用于撑爆链接长度上限`,
      deviceCount: index,
      onlineDeviceCount: index,
    }));
    const url = FeedbackDiagnosticsBuilder.issueURL({
      appVersion: "1.5.0",
      osVersion: "Windows 10/11",
      platform: "Windows",
      backends,
      signals: [{ code: "MI_AUTH", count: 3 }],
    });
    assert.ok(url);
    assert.ok(url.length <= FeedbackDiagnosticsBuilder.maxURLLength, `${url.length} exceeds the ceiling`);
    const block = new URL(url).searchParams.get("diagnostics") ?? "";
    assert.ok(block.includes("1.5.0"), "the first line is the last thing to go");
    assert.ok(block.includes("…"), "a truncated block says so");
  });

  it("names an error category with a stable code and leaves zero counts out", () => {
    const signals = feedbackSignals({
      sessionExpired: true,
      categoryCounts: { miCloud: 2, homeAssistant: 0, camera: 1, command: 0, auth: 3, rateLimit: 0, network: 0, unknown: 0 },
    });
    assert.deepEqual(signals, [
      { code: "MI_CLOUD", count: 2 },
      { code: "CAMERA", count: 1 },
      { code: "MI_AUTH", count: 3 },
      { code: "MI_SESSION_EXPIRED", count: 1 },
    ]);
    const block = FeedbackDiagnosticsBuilder.block({
      appVersion: "1.5.0",
      osVersion: "Windows 10/11",
      platform: "Windows",
      signals,
    });
    assert.ok(block.includes("MI_SESSION_EXPIREDx1"));
    assert.ok(!block.includes("RATE_LIMIT"));
  });

  it("counts devices per source, defaulting an unowned device to the live source", () => {
    const devices = [
      { id: "a", isOnline: true, sourceBackend: "xiaomiCloud" },
      { id: "b", isOnline: false, sourceBackend: "homeAssistant" },
      { id: "c", isOnline: true },
    ] as unknown as SmartDevice[];

    assert.deepEqual(
      countFeedbackBackendDevices(devices, "xiaomiCloud", { defaultBackend: "homeAssistant" }),
      { deviceCount: 1, onlineDeviceCount: 1 },
    );
    assert.deepEqual(
      countFeedbackBackendDevices(devices, "homeAssistant", {
        defaultBackend: "homeAssistant",
        deviceBackends: { b: "homeAssistant" },
      }),
      { deviceCount: 2, onlineDeviceCount: 1 },
    );
  });
});
