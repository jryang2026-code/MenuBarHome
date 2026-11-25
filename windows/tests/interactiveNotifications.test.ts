import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";

import { setLanguage } from "../src/core/i18n.js";
import type { DeviceCommand } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import {
  getHostActivityCenter,
  ingestHostHASnapshotForDoorbell,
  recordSafetyAlerts,
} from "../src/ui/activityStackView.js";
import { enqueueIncomingOpenUrl } from "../src/ui/speechGuard.js";
import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";

let dom: Window;

async function flushAsync(): Promise<void> {
  await setImmediate();
  await setImmediate();
}

function startApp(overrides: Record<string, unknown> = {}): MenuMijiaWindowsApp {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
      blockControlWhileLocked: true,
      interfaceLanguage: "zh-Hans",
      ...overrides,
    }),
  );
  const root = document.getElementById("app")!;
  const app = new MenuMijiaWindowsApp(root);
  app.render();
  return app;
}

describe("Windows interactive notifications", () => {
  beforeEach(() => {
    dom = mountTestWindow();
    installCssEscape();
    setLanguage("zh-Hans");
    localStorage.clear();
  });

  afterEach(async () => {
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("attaches at most 2 safe actions to actionable alerts, runs turn-off through applyCommand when unlocked, and blocks + retries across workstation lock", async () => {
    let locked = false;
    const toastPayloads: Array<{
      readonly title: string;
      readonly body: string;
      readonly kind?: string;
      readonly deviceId?: string;
      readonly actions?: ReadonlyArray<{ readonly label: string; readonly arguments: string }>;
    }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (name: string, args: unknown) => {
          if (name === "is_workstation_locked") return locked;
          if (name === "send_desktop_notification") {
            toastPayloads.push(args as (typeof toastPayloads)[number]);
          }
          return null;
        },
      },
    });

    const app = startApp();
    const plug = app.devices.find((d) => d.kind.kind === "plug");
    assert.ok(plug && plug.kind.kind === "plug");
    const commands: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      commands.push(cmd);
      return true;
    };

    const turnOffCommand: DeviceCommand = {
      kind: "setSwitch",
      entityId: plug.kind.switchEntityId,
      isOn: false,
    };
    recordSafetyAlerts(app, [
      {
        id: `longrun:${plug.id}`,
        deviceId: plug.id,
        title: `${plug.name} 已开启超过 45 分钟`,
        body: "点击关闭",
        category: "longRun",
        priority: "high",
        turnOffCommand,
      },
    ]);
    await flushAsync();

    assert.equal(toastPayloads.length, 1);
    const actions = toastPayloads[0]!.actions ?? [];
    assert.equal(actions.length, 2);
    assert.equal(actions[0]!.label, "立即关闭");
    assert.match(actions[0]!.arguments, /^menumijia:\/\/notification\/action\/[a-zA-Z0-9_-]{16,128}$/);
    assert.equal(actions[1]!.label, "查看");
    assert.equal(actions[1]!.arguments, `menumijia://notification/safety/${plug.id}`);
    assert.equal(
      actions.some((a) => /unlock|open_lock/i.test(a.arguments)),
      false,
    );

    const turnOffUrl = actions[0]!.arguments;

    // 1. Forged action token never executes commands.
    await enqueueIncomingOpenUrl(app, "menumijia://notification/action/forged_token_0123456789abcdef");
    assert.equal(commands.length, 0);

    // 2. Locked workstation blocks both turn-off and view actions, keeping the token retryable.
    locked = true;
    await enqueueIncomingOpenUrl(app, turnOffUrl);
    await enqueueIncomingOpenUrl(app, actions[1]!.arguments);
    assert.equal(commands.length, 0);
    assert.equal(app.panelSearch.selectedDeviceId, null);

    // 3. Unlocking allows retrying the preserved token through the normal control path.
    locked = false;
    await enqueueIncomingOpenUrl(app, turnOffUrl);
    assert.deepEqual(commands, [turnOffCommand]);
  });

  it("rejects stale action tokens after home/source switch", async () => {
    const toastPayloads: Array<{ readonly actions?: ReadonlyArray<{ readonly arguments: string }> }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (name: string, args: unknown) => {
          if (name === "is_workstation_locked") return false;
          if (name === "send_desktop_notification") {
            toastPayloads.push(args as { readonly actions?: ReadonlyArray<{ readonly arguments: string }> });
          }
          return null;
        },
      },
    });

    const app = startApp();
    const plug = app.devices.find((d) => d.kind.kind === "plug")!;
    assert.ok(plug.kind.kind === "plug");
    const commands: DeviceCommand[] = [];
    app.applyCommand = async (cmd) => {
      commands.push(cmd);
      return true;
    };

    recordSafetyAlerts(app, [
      {
        id: `longrun:${plug.id}`,
        deviceId: plug.id,
        title: "长开提醒",
        body: "点击关闭",
        category: "longRun",
        priority: "high",
        turnOffCommand: { kind: "setSwitch", entityId: plug.kind.switchEntityId, isOn: false },
      },
    ]);
    await flushAsync();
    const turnOffUrl = toastPayloads[0]!.actions![0]!.arguments;

    // Switching source invalidates in-memory pending notification tokens.
    app.sourceEpoch.advance("source");
    getHostActivityCenter(app);
    await enqueueIncomingOpenUrl(app, turnOffUrl);
    assert.equal(commands.length, 0);
    assert.equal(app.replyBanner?.isError, true);
    assert.match(app.replyBanner?.text ?? "", /不适用/);
  });

  it("attaches View Live action to doorbell notifications and blocks camera open while locked", async () => {
    let locked = true;
    let revealCalls = 0;
    const toastPayloads: Array<{
      readonly kind?: string;
      readonly actions?: ReadonlyArray<{ readonly label: string; readonly arguments: string }>;
    }> = [];
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      configurable: true,
      value: {
        invoke: async (name: string, args: unknown) => {
          if (name === "is_workstation_locked") return locked;
          if (name === "show_panel_for_url") revealCalls += 1;
          if (name === "send_desktop_notification") {
            toastPayloads.push(args as (typeof toastPayloads)[number]);
          }
          return null;
        },
      },
    });

    const app = startApp();
    const cam = app.devices.find((d) => d.kind.kind === "camera");
    assert.ok(cam && cam.kind.kind === "camera", "demo home should include a camera");
    let openedCameraId: string | null = null;
    app.cameraLive.openCameraLiveView = (id: string) => {
      openedCameraId = id;
    };

    const baseSnap = {
      entities: [
        { entity_id: cam.kind.entityId, device_id: "dev_cam_db" },
        { entity_id: "event.front_doorbell", device_id: "dev_cam_db" },
      ],
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-25T01:00:00Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };
    await ingestHostHASnapshotForDoorbell(app, baseSnap, { isLocked: false, autoPopup: false });
    await ingestHostHASnapshotForDoorbell(
      app,
      {
        ...baseSnap,
        states: [
          {
            entity_id: "event.front_doorbell",
            state: "2026-11-25T01:01:00Z",
            attributes: { device_class: "doorbell" },
          },
        ],
      },
      { isLocked: false, autoPopup: false },
    );
    await flushAsync();

    const doorbellToast = toastPayloads.find((p) => p.kind === "doorbell");
    assert.ok(doorbellToast);
    assert.deepEqual(doorbellToast.actions, [
      { label: "查看画面", arguments: `menumijia://notification/doorbell/${cam.id}` },
    ]);

    // Locked: clicking "查看画面" must be blocked.
    await enqueueIncomingOpenUrl(app, doorbellToast.actions![0]!.arguments);
    assert.equal(openedCameraId, null);
    assert.equal(revealCalls, 0);

    // Unlocked: clicking "查看画面" opens live camera and reveals panel.
    locked = false;
    await enqueueIncomingOpenUrl(app, doorbellToast.actions![0]!.arguments);
    assert.equal(openedCameraId, cam.id);
    assert.equal(revealCalls, 1);
  });
});
