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
  type DdcDisplayMetadata,
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

const REDMI_DISPLAY: DdcDisplayMetadata = {
  id: "65537", name: "Redmi G27U", manufacturer: "RED", model: "Redmi G27U", isRedmiOrXiaomi: true,
  brightnessPercent: 72, brightnessMax: 100, volumePercent: 35, volumeMax: 100, isMuted: false,
  inputSource: 0x11, supportedInputSources: [0x0f, 0x10, 0x11, 0x12, 0x1b],
  supportsBrightness: true, supportsVolume: true, supportsMute: true, supportsInputSource: true,
};

function recordingInvoke(displays: readonly (DdcDisplayMetadata | string)[] = [REDMI_DISPLAY]) {
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

  it("renders real monitor name, Xiaomi badge, readback slider values, and active input", async () => {
    const { calls, invoke } = recordingInvoke();
    const ctrl = new DdcDisplayController({
      invoke,
      storage: memoryStorage({ [EXTERNAL_DISPLAY_DDC_STORAGE_KEY]: "true" }),
    });
    ctrl.onPanelShown();
    await ctrl.settle();
    assert.deepEqual(calls.map((c) => c.cmd), ["ddc_list_displays"]);
    const html = renderDdcPanelSection(ctrl, esc);
    assert.ok(html.includes("Redmi G27U") && /data-ddc-xiaomi-badge/.test(html) && /外接显示器 · 当前 HDMI 1/.test(html));
    assert.match(html, /data-ddc-brightness-value="65537">72%/);
    assert.match(html, /data-ddc-volume-value="65537">35%/);
    assert.match(html, /data-ddc-input="65537" data-ddc-source="17" aria-pressed="true"/);
    for (const label of ["DP 1", "DP 2", "HDMI 1", "HDMI 2", "USB-C"]) assert.ok(html.includes(label), label);
    assert.match(html, /data-ddc-mute="65537"/);
    assert.doesNotMatch(html, /0xD6|data-ddc-power/i);
    const settingsHtml = renderDdcSettingsSection(ctrl, esc);
    assert.ok(settingsHtml.includes("Redmi G27U") && /data-ddc-xiaomi-badge/.test(settingsHtml) && /亮度 72% · HDMI 1/.test(settingsHtml));
  });

  it("hides volume controls on speakerless monitors and only shows supported inputs", async () => {
    const dell: DdcDisplayMetadata = {
      id: "70001", name: "DELL U2723QE", manufacturer: "DEL", model: "U2723QE", isRedmiOrXiaomi: false,
      brightnessPercent: 60, brightnessMax: 255, volumePercent: null, volumeMax: null, isMuted: null,
      inputSource: 0x1b, supportedInputSources: [0x0f, 0x1b, 0x1c],
      supportsBrightness: true, supportsVolume: false, supportsMute: false, supportsInputSource: true,
    };
    const { calls, invoke } = recordingInvoke([dell]);
    const ctrl = new DdcDisplayController({ invoke, storage: memoryStorage({ [EXTERNAL_DISPLAY_DDC_STORAGE_KEY]: "true" }) });
    await ctrl.refresh();
    const html = renderDdcPanelSection(ctrl, esc);
    assert.ok(html.includes("DELL U2723QE") && html.includes("DP 1") && html.includes("USB-C") && html.includes("0x1C") && !html.includes("HDMI 2"));
    assert.doesNotMatch(html, /data-ddc-xiaomi-badge|data-ddc-volume=|data-ddc-mute=/);
    assert.match(html, /data-ddc-brightness-value="70001">60%</);
    const before = calls.length;
    await ctrl.setVolume("70001", 40); await ctrl.setMute("70001", true); await ctrl.setInputSource("70001", 0x12);
    assert.equal(calls.length, before);
    await ctrl.setInputSource("70001", 0x1c);
    assert.deepEqual(calls.slice(before), [{ cmd: "ddc_set_input_source", args: { displayId: "70001", source: 0x1c } }]);
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
    assert.equal(brightness.value, "72");
    brightness.value = "37";
    brightness.dispatchEvent(new win.Event("input", { bubbles: true }) as unknown as Event);
    assert.equal(calls.filter((c) => c.cmd === "ddc_set_brightness").length, 0, "dragging alone does not write");
    brightness.dispatchEvent(new win.Event("change", { bubbles: true }) as unknown as Event);

    root.querySelector<HTMLElement>('[data-ddc-input="65537"][data-ddc-source="17"]')!.click();
    root.querySelector<HTMLElement>('[data-ddc-input="65537"][data-ddc-source="15"]')!.click();

    const volume = root.querySelector<HTMLInputElement>('input[data-ddc-volume="65537"]')!;
    assert.equal(volume.value, "35");
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
        if (cmd === "ddc_list_displays") return [{ ...REDMI_DISPLAY, id: "1" }];
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
