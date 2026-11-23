import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import {
  diagnoseEmptyPanel,
  suggestedActionForEmptyPanelReason,
  type EmptyPanelDiagnosisInput,
  type EmptyPanelReason,
  type EmptyPanelSuggestedAction,
} from "../src/core/emptyPanelDiagnosis.js";
import { setLanguage } from "../src/core/i18n.js";
import type { MiSession } from "../src/core/miCloudClient.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

interface GoldenCase {
  readonly id: string;
  readonly input: EmptyPanelDiagnosisInput;
  readonly expectedReason: EmptyPanelReason | null;
  readonly expectedAction: EmptyPanelSuggestedAction | null;
}

interface GoldenFile {
  readonly version: number;
  readonly cases: readonly GoldenCase[];
}

describe("EmptyPanelDiagnosis golden corpus", () => {
  const fixturePath = resolve(import.meta.dirname, "../../Tests/Fixtures/empty_panel_diagnosis_golden.json");
  const golden = JSON.parse(readFileSync(fixturePath, "utf8")) as GoldenFile;

  it("matches every case in empty_panel_diagnosis_golden.json", () => {
    assert.equal(golden.version, 1);
    assert.ok(golden.cases.length > 0);
    for (const item of golden.cases) {
      const reason = diagnoseEmptyPanel(item.input);
      assert.equal(reason, item.expectedReason, `Case ${item.id}: reason mismatch`);
      const action = reason ? suggestedActionForEmptyPanelReason(reason) : null;
      assert.equal(action, item.expectedAction, `Case ${item.id}: action mismatch`);
    }
  });
});

describe("Windows empty-panel diagnosis UI", () => {
  let win: Window;
  let app: MenuMijiaWindowsApp | null = null;

  const SESSION: MiSession = {
    userId: "100200300",
    cUserId: "",
    ssecurity: "AQIDBAUGBwgJCgsMDQ4PEA==",
    serviceToken: "tok",
    passToken: "",
    region: "cn",
  };

  beforeEach(() => {
    setLanguage("zh-Hans");
    win = mountTestWindow();
  });

  afterEach(() => {
    app?.dispose();
    app = null;
    closeTestWindow(win);
  });

  async function createCloudApp(region = "cn"): Promise<MenuMijiaWindowsApp> {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ code: 0, result: { list: [], homelist: [] } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof fetch;
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        interfaceLanguage: "zh-Hans",
        hasCompletedOnboarding: true,
        miCloudRegion: region,
        miSession: { ...SESSION, region },
      }),
    );
    const root = document.getElementById("app") as HTMLElement;
    const instance = new MenuMijiaWindowsApp(root);
    app = instance;
    await new Promise((r) => setTimeout(r, 15));
    instance.isSyncingCloud = false;
    instance.devices = [];
    instance.homes = [];
    instance.cloudValuesStale = false;
    instance.miSessionExpired = false;
    instance.replyBanner = null;
    return instance;
  }

  it("renders switchRegion for overseas 0-home account and jumps to miCloudRegion anchor", async () => {
    const instance = await createCloudApp("sg");
    instance.render();

    const empty = document.querySelector<HTMLElement>("#empty-mi-diagnosis");
    assert.ok(empty, "expected #empty-mi-diagnosis to render");
    assert.equal(empty.dataset.emptyReason, "possibleWrongRegion");
    const btn = document.querySelector<HTMLElement>("#btn-empty-switch-region");
    assert.ok(btn, "expected switch-region button");

    btn.click();
    assert.equal(instance.activeSheet, "settings");
    assert.equal(instance.settingsTab, "connection");
    const highlighted = document.querySelector<HTMLElement>('[data-settings-anchor="miCloudRegion"]');
    assert.equal(highlighted?.getAttribute("data-settings-highlighted"), "miCloudRegion");
  });

  it("renders confirmMiHome for cn 0-home account and jumps to miAccount anchor", async () => {
    const instance = await createCloudApp("cn");
    instance.render();

    const empty = document.querySelector<HTMLElement>("#empty-mi-diagnosis");
    assert.equal(empty?.dataset.emptyReason, "noHomes");
    const btn = document.querySelector<HTMLElement>("#btn-empty-confirm-mi-home");
    assert.ok(btn, "expected confirm-mi-home button");

    btn.click();
    assert.equal(instance.activeSheet, "settings");
    assert.equal(instance.settingsTab, "connection");
    const highlighted = document.querySelector<HTMLElement>('[data-settings-anchor="miAccount"]');
    assert.equal(highlighted?.getAttribute("data-settings-highlighted"), "miAccount");
  });

  it("renders copyDiagnostics for homesWithoutDevices and syncFailed, and copies report", async () => {
    const instance = await createCloudApp("cn");
    instance.homes = [{ id: "h1", name: "我的家", deviceCount: 0 }];
    instance.render();

    assert.equal(document.querySelector<HTMLElement>("#empty-mi-diagnosis")?.dataset.emptyReason, "homesWithoutDevices");
    const btn = document.querySelector<HTMLElement>("#btn-empty-copy-diagnostics");
    assert.ok(btn, "expected copy-diagnostics button");
    btn.click();
    await new Promise((r) => setTimeout(r, 20));
    assert.ok(
      (instance.connDiagSession.diagMarkdownPreview ?? "").length > 0,
      `expected diagnostics preview to be populated, banner=${JSON.stringify(instance.replyBanner)}`,
    );
    assert.ok(
      instance.replyBanner?.text.includes("诊断报告"),
      `expected diagnostics copy banner, got ${JSON.stringify(instance.replyBanner)}`,
    );

    // syncFailed also offers copyDiagnostics, even on a first-sync failure where cloudValuesStale is false.
    instance.homes = [];
    instance.cloudValuesStale = false;
    instance.lastMiCloudSyncFailed = true;
    instance.render();
    assert.equal(document.querySelector<HTMLElement>("#empty-mi-diagnosis")?.dataset.emptyReason, "syncFailed");
    assert.ok(document.querySelector("#btn-empty-copy-diagnostics"));
  });

  it("renders diagnosis in dual-source Home Assistant mode when 0 devices are shown", async () => {
    const instance = await createCloudApp("sg");
    instance.settings.connectionMode = "homeAssistant";
    instance.settings.haBaseURL = "http://192.168.1.2:8123";
    instance.settings.haToken = "ha-tok";
    instance.dualSourceEnabledOverride = true;
    instance.render();

    const empty = document.querySelector<HTMLElement>("#empty-mi-diagnosis");
    assert.ok(empty, "expected #empty-mi-diagnosis in dual-source HA mode");
    assert.equal(empty.dataset.emptyReason, "possibleWrongRegion");
    assert.ok(document.querySelector("#btn-empty-switch-region"));
  });

  it("renders sessionReauthRequired with reauth button when session is expired", async () => {
    const instance = await createCloudApp("cn");
    instance.miSessionExpired = true;
    instance.render();

    const empty = document.querySelector<HTMLElement>("#empty-mi-diagnosis");
    assert.equal(empty?.dataset.emptyReason, "sessionReauthRequired");
    assert.ok(document.querySelector("#btn-empty-reauth"));
    assert.equal(document.querySelector("#btn-empty-resync"), null);
  });

  it("never renders in demo mode", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
      }),
    );
    const root = document.getElementById("app") as HTMLElement;
    const instance = new MenuMijiaWindowsApp(root);
    app = instance;
    instance.devices = [];
    instance.render();

    assert.equal(instance.emptyPanelDiagnosis(), null);
    assert.equal(document.querySelector("#empty-mi-diagnosis"), null);
  });

  it("forwards anchor to open_settings_window when packaged Tauri metadata is present", async () => {
    const invoked: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
    const prevTauri = Object.getOwnPropertyDescriptor(window, "__TAURI_INTERNALS__");
    const mockTauri = () => {
      Object.defineProperty(window, "__TAURI_INTERNALS__", {
        value: {
          metadata: { currentWindow: { label: "main" } },
          invoke: async (cmd: string, args?: Record<string, unknown>) => {
            invoked.push({ cmd, args });
            return null;
          },
        },
        configurable: true,
      });
    };
    const restoreTauri = () => {
      if (prevTauri) {
        Object.defineProperty(window, "__TAURI_INTERNALS__", prevTauri);
      } else {
        delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
      }
    };
    try {
      const sgApp = await createCloudApp("sg");
      sgApp.render();
      mockTauri();
      const switchRegionBtn = document.querySelector<HTMLElement>("#btn-empty-switch-region");
      assert.ok(switchRegionBtn, "expected #btn-empty-switch-region");
      switchRegionBtn.click();
      assert.deepEqual(
        invoked.find((c) => c.cmd === "open_settings_window"),
        { cmd: "open_settings_window", args: { tab: "connection", anchor: "miCloudRegion" } },
      );
      assert.equal(sgApp.activeSheet, "none");

      sgApp.dispose();
      app = null;
      invoked.length = 0;
      restoreTauri();
      document.body.innerHTML = '<div id="app"></div>';

      const cnApp = await createCloudApp("cn");
      cnApp.render();
      mockTauri();
      const confirmHomeBtn = document.querySelector<HTMLElement>("#btn-empty-confirm-mi-home");
      assert.ok(confirmHomeBtn, "expected #btn-empty-confirm-mi-home");
      confirmHomeBtn.click();
      assert.deepEqual(
        invoked.find((c) => c.cmd === "open_settings_window"),
        { cmd: "open_settings_window", args: { tab: "connection", anchor: "miAccount" } },
      );
      assert.equal(cnApp.activeSheet, "none");
    } finally {
      restoreTauri();
    }
  });
});

