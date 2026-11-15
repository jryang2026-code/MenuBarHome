import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Window } from "happy-dom";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { SliderStepSnap } from "../src/ui/liquidGlassSlider.js";
import { StackedCardGeometry, collectUpperStackCards, dismissUpperStackCard, getHostActivityCenter, recordSafetyAlerts } from "../src/ui/activityStackView.js";
import { scopedKey } from "../src/ui/panelPrefs.js";
import type { DeviceCommand } from "../src/core/models.js";

let dom: Window;
let app: MenuMijiaWindowsApp | null = null;

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const result = document.querySelector<T>(selector);
  assert.ok(result, `Missing ${selector}`);
  return result;
}

beforeEach(() => { dom = mountTestWindow(); });
afterEach(async () => { app?.dispose(); app = null; await closeTestWindow(dom); });

describe("SliderStepSnap & LiquidGlassSlider 28px Pill Track", () => {
  it("snaps non-divisible ranges (2000..6535K step 100) cleanly to max and computes decile buckets", () => {
    for (const [raw, expected] of [[2000, 2000], [4240, 4200], [6510, 6500], [6520, 6535], [6535, 6535]] as const) {
      assert.equal(SliderStepSnap.snap(raw, 2000, 6535, 100), expected);
    }
    assert.equal(SliderStepSnap.stepBy(6500, 100, 2000, 6535, 100), 6535);
    assert.equal(SliderStepSnap.stepBy(6535, -100, 2000, 6535, 100), 6500);
    for (const [val, bucket] of [[0, 0], [29, 2], [30, 3], [100, 10]] as const) {
      assert.equal(SliderStepSnap.decileBucket(val, 0, 100), bucket);
    }
  });

  it("renders LiquidGlassSlider across light, tv, and humidifier, updates live drag state, dispatches DeviceCommand, and holds mid-drag across reconciler renders", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    app = new MenuMijiaWindowsApp(element("#app"));
    const light = app.devices.find((d) => d.id === "light.living_ceiling")!;
    if (light.kind.kind === "light") light.kind = { ...light.kind, minKelvin: 2000, maxKelvin: 6535, colorTempKelvin: 4000 };
    app.devices.push(
      { id: "tv.living_oled", name: "客厅电视", roomId: "room_living", roomName: "客厅", model: "xiaomi.tv.oled1", isOnline: true, kind: { kind: "tv", mediaEntityId: "miot:tv.living_oled:2", state: "playing", volumePercent: 30, isMuted: false, muteSwitchEntityId: "miot:tv.living_oled:3", currentSource: "HDMI 1", availableSources: ["HDMI 1", "HDMI 2"], volumeWritable: true, volumePresent: true } },
      { id: "humidifier.bedroom_mist", name: "卧室加湿器", roomId: "room_bedroom", roomName: "主卧", model: "zhimi.humidifier.ca4", isOnline: true, kind: { kind: "humidifier", entityId: "miot:humidifier.bedroom_mist:2", isOn: true, currentMode: "Auto", availableModes: ["Auto", "Sleep"], modeWritable: true, targetHumidity: 50, minHumidity: 30, maxHumidity: 80, step: 1, humidityWritable: true, currentHumidity: 45, powerWritable: true } },
    );
    for (const id of ["light.living_ceiling", "tv.living_oled", "humidifier.bedroom_mist"]) {
      app.layout.tileSizes[scopedKey(app.pageKey, id)] = "full";
    }
    app.render();

    const dispatched: DeviceCommand[] = [];
    const origApply = app.applyCommand.bind(app);
    app.applyCommand = async (cmd: DeviceCommand, silent?: boolean) => { dispatched.push(cmd); return origApply(cmd, silent); };

    const inlineLightInput = element<HTMLInputElement>('input[data-inline-brightness="light.living_ceiling"]');
    const inlineLightWrap = inlineLightInput.closest<HTMLElement>(".cc-liquid-slider")!;
    assert.equal(inlineLightWrap.dataset.liquidSlider, "inline");

    app.pointerIsDown = true;
    inlineLightInput.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    inlineLightInput.value = "84";
    inlineLightInput.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(inlineLightWrap.classList.contains("is-dragging"), true);
    assert.equal(inlineLightWrap.style.getPropertyValue("--fill-scale"), "0.8384");
    assert.equal(inlineLightWrap.querySelector(".cc-liquid-readout")?.textContent, "84%");

    app.render();
    assert.equal(inlineLightInput.value, "84");
    assert.equal(inlineLightWrap.classList.contains("is-dragging"), true);
    assert.equal(inlineLightWrap.style.getPropertyValue("--fill-scale"), "0.8384");

    app.pointerIsDown = false;
    inlineLightInput.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(inlineLightWrap.classList.contains("is-dragging"), false);
    assert.equal(dispatched.some((c) => c.kind === "setLightBrightness" && c.percent === 84), true);

    app.expandedDeviceId = "light.living_ceiling";
    app.render();
    const kelvinInput = element<HTMLInputElement>('input[data-colortemp="light.living_ceiling"]');
    const kelvinWrap = kelvinInput.closest<HTMLElement>(".cc-liquid-slider")!;
    assert.equal(kelvinWrap.classList.contains("is-kelvin"), true);
    assert.equal(kelvinWrap.querySelectorAll(".cc-liquid-tick").length, 9);
    kelvinInput.value = "6525";
    kelvinInput.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(kelvinInput.value, "6535");
    assert.equal(kelvinWrap.style.getPropertyValue("--fill-scale"), "1.0000");
    assert.equal(kelvinWrap.querySelector(".cc-liquid-readout")?.textContent, "6535K");
    kelvinInput.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(dispatched.some((c) => c.kind === "setLightColorTemp" && c.kelvin === 6535), true);

    const tvVolInput = element<HTMLInputElement>('input[data-inline-volume="tv.living_oled"]');
    const tvVolWrap = tvVolInput.closest<HTMLElement>(".cc-liquid-slider")!;
    tvVolInput.value = "65";
    tvVolInput.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(tvVolWrap.style.getPropertyValue("--fill-scale"), "0.6500");
    assert.equal(tvVolWrap.querySelector(".cc-liquid-readout")?.textContent, "65%");
    tvVolInput.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(dispatched.some((c) => c.kind === "mediaSetVolume" && Math.abs(c.level - 0.65) < 1e-6), true);

    const humInput = element<HTMLInputElement>('input[data-inline-humidity="humidifier.bedroom_mist"]');
    const humWrap = humInput.closest<HTMLElement>(".cc-liquid-slider")!;
    humInput.value = "55";
    humInput.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(humWrap.style.getPropertyValue("--fill-scale"), "0.5000");
    assert.equal(humWrap.querySelector(".cc-liquid-readout")?.textContent, "55%");
    humInput.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.equal(dispatched.some((c) => c.kind === "setHumidity" && c.percent === 55), true);
  });
});

describe("Unified Collapsible Upper Stack with 3-Card Peek & Swipe-to-Dismiss", () => {
  it("consolidates proactive suggestions, 10m undo, and activity cards with 3-card peek backplates, fan-out toggle, swipe-to-dismiss, and rubber-band on non-dismissible cards", () => {
    assert.deepEqual(StackedCardGeometry.backplateTransform(0), { scale: 1, scaleX: 1, offsetY: 0, opacity: 1 });
    assert.deepEqual(StackedCardGeometry.backplateTransform(1), { scale: 0.94, scaleX: 0.94, offsetY: 8, opacity: 0.78 });
    assert.deepEqual(StackedCardGeometry.backplateTransform(2), { scale: 0.88, scaleX: 0.88, offsetY: 15, opacity: 0.55 });
    assert.equal(StackedCardGeometry.shouldDismiss({ translationPx: 180, velocityPxPerSec: 100, widthPx: 400 }), true);
    assert.equal(StackedCardGeometry.shouldDismiss({ translationPx: 40, velocityPxPerSec: 900, widthPx: 400 }), true);
    assert.equal(StackedCardGeometry.shouldDismiss({ translationPx: 40, velocityPxPerSec: 100, widthPx: 400 }), false);

    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "demo", hasCompletedOnboarding: true, panelTheme: "classic" }));
    app = new MenuMijiaWindowsApp(element("#app"));
    app.isShowingAssistantBar = false;
    const nowMs = Date.now();
    recordSafetyAlerts(app, [{ id: "longrun:light.living_ceiling", deviceId: "light.living_ceiling", category: "longRun", priority: "normal", title: "客厅主灯已连续开启 8 小时", body: "建议确认是否需要关闭" }], nowMs);
    app.lastUndoAction = { summary: "已关闭客厅主灯", expiresAtMs: nowMs + 600_000, steps: [{ deviceId: "light.living_ceiling", commands: [{ kind: "setSwitch", entityId: "light.living_ceiling", isOn: true }] }] };
    app.undoBannerUntilMs = nowMs + 600_000;
    app.currentProactiveSuggestions = () => [{ id: "proactive-study-lamp", title: "打开书房台灯", confidencePercent: 88, intents: [{ targetId: "light.study_desk", operation: { kind: "power", isOn: true } }] }];
    app.render();

    assert.deepEqual(collectUpperStackCards(app, nowMs).map((c) => c.kind), ["safety", "undo", "proactive"]);
    const stack = element<HTMLElement>("[data-upper-stack]");
    assert.equal(stack.classList.contains("is-collapsed"), true);
    assert.equal(stack.dataset.activityCount, "3");
    assert.ok(stack.querySelector('[data-stack-peek="1"]') && stack.querySelector('[data-stack-peek="2"]'));

    element<HTMLButtonElement>("[data-activity-toggle-expand]").click();
    const expandedStack = element<HTMLElement>("[data-upper-stack]");
    assert.equal(expandedStack.classList.contains("is-expanded"), true);
    assert.equal(expandedStack.querySelectorAll("[data-upper-card-id]").length, 3);
    assert.ok(expandedStack.querySelector("[data-proactive-bar]"));

    const swipeCard = (el: HTMLElement, ptrId: number, x0: number, x1: number, x2?: number): void => {
      el.dispatchEvent(new dom.PointerEvent("pointerdown", { clientX: x0, clientY: 20, pointerId: ptrId, bubbles: true }) as unknown as Event);
      el.dispatchEvent(new dom.PointerEvent("pointermove", { clientX: x1, clientY: 20, pointerId: ptrId, bubbles: true }) as unknown as Event);
      if (x2 !== undefined) el.dispatchEvent(new dom.PointerEvent("pointerup", { clientX: x2, clientY: 20, pointerId: ptrId, bubbles: true }) as unknown as Event);
    };
    swipeCard(element<HTMLElement>('[data-upper-card-id="proactive:suggestions"]'), 1, 200, 380, 390);
    assert.equal(document.querySelector('[data-upper-card-id="proactive:suggestions"]'), null);
    swipeCard(element<HTMLElement>('[data-upper-card-id="undo:manual"]'), 2, 200, 20, 10);
    assert.equal(app.lastUndoAction, null);
    assert.equal(document.querySelector('[data-upper-card-id="undo:manual"]'), null);

    app.lastUndoAction = { summary: "已打开书房台灯", expiresAtMs: nowMs + 605_000, steps: [{ deviceId: "light.study_desk", commands: [{ kind: "setSwitch", entityId: "light.study_desk", isOn: false }] }] };
    app.undoBannerUntilMs = nowMs + 605_000;
    app.render();
    assert.ok(document.querySelector('[data-upper-card-id="undo:manual"]'));
    dismissUpperStackCard(app, "undo:manual");
    app.render();

    app.scheduledCommands = [{ id: "sched-active-1", command: "10 分钟后关主灯", delaySeconds: 600, fireTimestampMs: nowMs + 600_000, reply: "已设置", intents: [{ targetId: "light.living_ceiling", operation: { kind: "power", isOn: false } }] }];
    app.missedScheduledCommands = [{ id: "sched-missed-1", command: "昨晚关空调", delaySeconds: 300, fireTimestampMs: nowMs - 60_000, reply: "已设置", intents: [{ targetId: "climate.living_ac", operation: { kind: "power", isOn: false } }] }];
    dismissUpperStackCard(app, "timers:active");
    assert.equal(app.scheduledCommands.length, 0);
    assert.equal(app.missedScheduledCommands.length, 1);
    assert.equal(app.missedScheduledCommands[0]?.id, "sched-missed-1");
    dismissUpperStackCard(app, "missed:timers");
    assert.equal(app.missedScheduledCommands.length, 0);

    app.haConnectionError = "Home Assistant 令牌无效";
    app.render();
    const haErrorCard = element<HTMLElement>('[data-upper-card-id="ha:error"]');
    assert.equal(haErrorCard.dataset.upperDismissible, "false");
    swipeCard(haErrorCard, 3, 100, 320);
    assert.equal(haErrorCard.style.transform, `translate3d(${StackedCardGeometry.rubberBand(220, 396).toFixed(2)}px, 0px, 0px)`);
    haErrorCard.dispatchEvent(new dom.PointerEvent("pointerup", { clientX: 320, clientY: 20, pointerId: 3, bubbles: true }) as unknown as Event);
    assert.ok(document.querySelector('[data-upper-card-id="ha:error"]'));
    assert.equal(haErrorCard.style.transform, "translate3d(0px, 0px, 0px)");

    const center = getHostActivityCenter(app);
    center.pendingHighRiskUndoRunId = "run-heater-1";
    center.recentAutomationRuns = [{ id: "run-heater-1", ruleId: "rule-1", trigger: "away", triggerTitle: "离开", summary: "已关闭取暖器", scope: center.scopeKey, firedAtMs: nowMs, expiresAtMs: nowMs + 600_000, steps: [], kindSnapshots: new Map() }];
    app.render();
    assert.equal(collectUpperStackCards(app, nowMs).find((c) => c.id === "auto:run-heater-1")?.isDismissible, false);
  });
});
