import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { closeTestWindow, installCssEscape, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  DdcDisplayController,
  EXTERNAL_DISPLAY_DDC_STORAGE_KEY,
  bindDdcDisplayEvents,
  renderDdcPanelSection,
  renderDdcSettingsSection,
  type DdcStorage,
} from "../src/ui/ddcDisplaySection.js";

const esc = (raw: string) => raw.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

function memoryStorage(initial: Record<string, string> = {}): DdcStorage & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem: (key) => data[key] ?? null,
    setItem: (key, value) => {
      data[key] = value;
    },
  };
}

function recordingInvoke(displays: string[] = ["65537"]) {
  const calls: { cmd: string; args?: Record<string, unknown> }[] = [];
  const invoke = async (cmd: string, args?: Record<string, unknown>) => {
    calls.push({ cmd, args });
    return cmd === "ddc_list_displays" ? displays : undefined;
  };
  return { calls, invoke };
}

describe("DDC/CI external display section", () => {
  let win: Window;
  let restoreCss: () => void;

  beforeEach(() => {
    win = mountTestWindow();
    restoreCss = installCssEscape();
    setLanguage("zh-Hans");
  });

  afterEach(async () => {
    restoreCss();
    await closeTestWindow(win);
  });

  it("is off by default and makes zero ddc_* IPC calls", async () => {
    const { calls, invoke } = recordingInvoke();
    const ctrl = new DdcDisplayController({ invoke, storage: memoryStorage() });
    assert.equal(ctrl.enabled, false);
    ctrl.onPanelShown();
    await ctrl.refresh();
    await ctrl.setBrightness("65537", 40);
    await ctrl.setInputSource("65537", 0x11);
    await ctrl.setMute("65537", true);
    await ctrl.settle();
    assert.deepEqual(calls, []);
    assert.equal(renderDdcPanelSection(ctrl, esc), "");
    assert.match(renderDdcSettingsSection(ctrl, esc), /外接显示器控制（DDC\/CI）/);
    assert.doesNotMatch(renderDdcSettingsSection(ctrl, esc), /data-ddc-scan/);
  });

  it("lists displays on panel show once enabled and renders brightness and DP/HDMI inputs", async () => {
    const { calls, invoke } = recordingInvoke();
    const ctrl = new DdcDisplayController({
      invoke,
      storage: memoryStorage({ [EXTERNAL_DISPLAY_DDC_STORAGE_KEY]: "true" }),
    });
    ctrl.onPanelShown();
    await ctrl.settle();
    assert.deepEqual(calls.map((c) => c.cmd), ["ddc_list_displays"]);
    const html = renderDdcPanelSection(ctrl, esc);
    assert.match(html, /data-ddc-brightness="65537"/);
    for (const label of ["DP 1", "DP 2", "HDMI 1", "HDMI 2", "USB-C"]) assert.ok(html.includes(label), label);
    assert.match(html, /data-ddc-mute="65537"/);
    assert.doesNotMatch(html, /0xD6|data-ddc-power/i);
  });

  it("dispatches ddc_set_* with the right arguments from the rendered card", async () => {
    const { calls, invoke } = recordingInvoke();
    const ctrl = new DdcDisplayController({
      invoke,
      storage: memoryStorage({ [EXTERNAL_DISPLAY_DDC_STORAGE_KEY]: "true" }),
    });
    await ctrl.refresh();
    const root = document.querySelector<HTMLElement>("#app")!;
    root.innerHTML = renderDdcPanelSection(ctrl, esc);
    bindDdcDisplayEvents(root, ctrl);

    const brightness = root.querySelector<HTMLInputElement>('input[data-ddc-brightness="65537"]')!;
    brightness.value = "37";
    brightness.dispatchEvent(new win.Event("input", { bubbles: true }) as unknown as Event);
    assert.equal(calls.filter((c) => c.cmd === "ddc_set_brightness").length, 0, "dragging alone does not write");
    brightness.dispatchEvent(new win.Event("change", { bubbles: true }) as unknown as Event);

    root.querySelector<HTMLElement>('[data-ddc-input="65537"][data-ddc-source="17"]')!.click();
    root.querySelector<HTMLElement>('[data-ddc-input="65537"][data-ddc-source="15"]')!.click();

    const volume = root.querySelector<HTMLInputElement>('input[data-ddc-volume="65537"]')!;
    volume.value = "22";
    volume.dispatchEvent(new win.Event("change", { bubbles: true }) as unknown as Event);
    root.querySelector<HTMLElement>('[data-ddc-mute="65537"]')!.click();
    await ctrl.settle();

    assert.deepEqual(calls.slice(1), [
      { cmd: "ddc_set_brightness", args: { displayId: "65537", percent: 37 } },
      { cmd: "ddc_set_input_source", args: { displayId: "65537", source: 0x11 } },
      { cmd: "ddc_set_input_source", args: { displayId: "65537", source: 0x0f } },
      { cmd: "ddc_set_volume", args: { displayId: "65537", percent: 22 } },
      { cmd: "ddc_set_mute", args: { displayId: "65537", muted: true } },
    ]);
    assert.ok(!calls.some((c) => JSON.stringify(c).includes("214")), "never sends power (0xD6)");
  });

  it("turning the switch off clears displays and stops IPC; the choice persists", async () => {
    const storage = memoryStorage();
    const { calls, invoke } = recordingInvoke();
    const ctrl = new DdcDisplayController({ invoke, storage });
    ctrl.setEnabled(true);
    assert.equal(storage.data[EXTERNAL_DISPLAY_DDC_STORAGE_KEY], "true");
    await ctrl.refresh();
    assert.equal(ctrl.displays.length, 1);
    ctrl.setEnabled(false);
    assert.equal(storage.data[EXTERNAL_DISPLAY_DDC_STORAGE_KEY], "false");
    assert.equal(renderDdcPanelSection(ctrl, esc), "");
    const before = calls.length;
    ctrl.onPanelShown();
    await ctrl.setVolume("65537", 10);
    await ctrl.settle();
    assert.equal(calls.length, before);
  });

  it("a failed write shows the DDC/CI hint", async () => {
    const ctrl = new DdcDisplayController({
      invoke: async (cmd) => {
        if (cmd === "ddc_list_displays") return ["1"];
        throw new Error("SetVCPFeature failed");
      },
      storage: memoryStorage({ [EXTERNAL_DISPLAY_DDC_STORAGE_KEY]: "true" }),
    });
    await ctrl.refresh();
    await ctrl.setInputSource("1", 0x12);
    assert.match(ctrl.error ?? "", /DDC\/CI/);
    assert.match(renderDdcPanelSection(ctrl, esc), /cc-ddc-error/);
  });
});
