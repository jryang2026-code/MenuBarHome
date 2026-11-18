import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { setLanguage } from "../src/core/i18n.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { STORAGE_KEY } from "../src/ui/appConstants.js";
import type {
  SpeechRecognitionEventLike,
  SpeechRecognitionInstance,
} from "../src/ui/appTypes.js";
import { loadSettings } from "../src/ui/settings.js";
import {
  isVoiceInputEnabled,
  setVoiceInputEnabled,
  toggleVoiceInput,
} from "../src/ui/speechGuard.js";

class FakeSpeechRecognition implements SpeechRecognitionInstance {
  static instances: FakeSpeechRecognition[] = [];
  static reset(): void {
    FakeSpeechRecognition.instances = [];
  }
  lang = "";
  interimResults = false;
  continuous = false;
  aborted = false;
  started = false;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null = null;
  onerror: (() => void) | null = null;
  onend: (() => void) | null = null;
  constructor() {
    FakeSpeechRecognition.instances.push(this);
  }
  start(): void {
    this.started = true;
  }
  stop(): void {}
  abort(): void {
    this.aborted = true;
  }
}

function seedLegacySettings(extra: Record<string, unknown> = {}): void {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
      ...extra,
    }),
  );
}

function storedSettings(): Record<string, unknown> {
  return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as Record<string, unknown>;
}

function changeCheckbox(id: string, checked: boolean): void {
  const box = document.querySelector<HTMLInputElement>(`#${id}`);
  assert.ok(box, `missing #${id}`);
  box.checked = checked;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
}

describe("Windows 语音输入 switch", () => {
  let dom: Window;
  let app: MenuMijiaWindowsApp;

  beforeEach(() => {
    dom = mountTestWindow({ stubInterval: true });
    Object.defineProperty(window, "__TAURI_INTERNALS__", {
      value: { invoke: async () => undefined },
      configurable: true,
    });
    seedLegacySettings();
    app = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
  });

  afterEach(async () => {
    setLanguage("zh-Hans");
    await closeTestWindow(dom);
  });

  it("keeps the mic entry for settings written before the switch existed", () => {
    const loaded = loadSettings();
    assert.equal(isVoiceInputEnabled(loaded.settings), true);
    assert.equal(loaded.settings.voiceInputEnabled, true);
    assert.ok(document.querySelector("#btn-mic"), "legacy users still see the mic button");
  });

  it("hides the entry, persists the choice and brings voice back when re-enabled", () => {
    app.openSettingsSheet();
    const box = document.querySelector<HTMLInputElement>("#settings-voice-input");
    assert.ok(box, "settings must expose 语音输入");
    assert.equal(box.checked, true);
    assert.match(
      document.querySelector('[data-settings-anchor="voiceControl"]')?.textContent ?? "",
      /语音输入/,
    );

    changeCheckbox("settings-voice-input", false);
    assert.equal(storedSettings().voiceInputEnabled, false);
    assert.equal(storedSettings().hasCompletedOnboarding, true, "other settings survive the write");
    assert.equal(document.querySelector("#btn-mic"), null, "mic entry is hidden while off");
    assert.ok(document.querySelector("#command-input"), "typed commands stay available");

    const reloaded = new MenuMijiaWindowsApp(document.querySelector<HTMLElement>("#app")!);
    assert.equal(isVoiceInputEnabled(reloaded.settings), false);
    assert.equal(document.querySelector("#btn-mic"), null, "choice survives a restart");

    reloaded.openSettingsSheet();
    changeCheckbox("settings-voice-input", true);
    assert.equal(storedSettings().voiceInputEnabled, true);
    assert.ok(document.querySelector("#btn-mic"), "mic entry returns");
  });

  it("aborts a live session on disable: no new recognizer, no timers, no late submission", () => {
    FakeSpeechRecognition.reset();
    window.SpeechRecognition = FakeSpeechRecognition;
    const instances = FakeSpeechRecognition.instances;

    const submitted: string[] = [];
    app.handleNaturalCommand = async (raw: string) => {
      submitted.push(raw);
    };

    toggleVoiceInput(app);
    assert.equal(app.isListeningVoice, true);
    assert.equal(instances.length, 1);
    const rec = instances[0]!;
    rec.onresult?.({ results: [{ 0: { transcript: "打开书房" }, isFinal: false }] });
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "打开书房");

    const timers: number[] = [];
    const originalSetTimeout = window.setTimeout;
    window.setTimeout = ((handler: Parameters<typeof window.setTimeout>[0], timeout?: number) => {
      timers.push(timeout ?? 0);
      return originalSetTimeout(handler, timeout);
    }) as typeof window.setTimeout;
    try {
      setVoiceInputEnabled(app, false);

      assert.equal(rec.aborted, true, "the live recognizer is aborted immediately");
      assert.equal(app.isListeningVoice, false);
      assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
      assert.equal(document.querySelector("#btn-mic"), null);

      // A stale click from the panel rendered before the switch must not start anything either.
      toggleVoiceInput(app);
      assert.equal(instances.length, 1, "no new recognizer after the switch is off");

      // Results that land after the abort belong to a closed session.
      rec.onresult?.({ results: [{ 0: { transcript: "关闭客厅灯" }, isFinal: true }] });
      rec.onend?.();
      assert.deepEqual(submitted, [], "late results must not submit or execute");
      assert.equal(timers.length, 0, "disabling voice schedules no timer");
    } finally {
      window.setTimeout = originalSetTimeout;
    }
  });

  it("reports unsupported Web Speech without pretending the switch is off", () => {
    delete (window as { SpeechRecognition?: unknown }).SpeechRecognition;
    delete (window as { webkitSpeechRecognition?: unknown }).webkitSpeechRecognition;

    app.openSettingsSheet();
    const box = document.querySelector<HTMLInputElement>("#settings-voice-input");
    assert.ok(box);
    assert.equal(box.checked, true, "the saved preference is what the switch shows");
    const hint = document.querySelector('[data-settings-anchor="voiceControl"]')?.textContent ?? "";
    assert.match(hint, /不支持/);

    const submitted: string[] = [];
    app.handleNaturalCommand = async (raw: string) => {
      submitted.push(raw);
    };
    toggleVoiceInput(app);
    assert.equal(app.isListeningVoice, false, "no recognizer starts without support");
    assert.match(app.replyBanner?.text ?? "", /语音识别/);
    assert.equal(isVoiceInputEnabled(app.settings), true, "an unsupported host does not flip the switch");
    assert.deepEqual(submitted, []);
  });

  it("keeps keyboard and typed commands working while voice is off", () => {
    const submitted: string[] = [];
    app.handleNaturalCommand = async (raw: string) => {
      submitted.push(raw);
    };
    setVoiceInputEnabled(app, false);
    assert.equal(document.querySelector("#btn-mic"), null);

    const input = document.querySelector<HTMLInputElement>("#command-input");
    assert.ok(input);
    input.value = "打开书房台灯";
    document.querySelector<HTMLElement>("#btn-send")?.click();
    assert.deepEqual(submitted, ["打开书房台灯"]);
  });
});
