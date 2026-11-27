import { tr3 } from "../core/i18n.js";
import { SF_ICONS } from "./appConstants.js";
import { renderLiquidGlassSlider } from "./liquidGlassSlider.js";

/**
 * Optional external-monitor control over DDC/CI (Redmi G27U and other DDC/CI displays), the Windows
 * twin of macOS `ExternalDisplayStore`. Off by default: while off it makes zero `ddc_*` IPC calls and
 * renders nothing, so the panel is unchanged. When on it lists displays only when the panel is shown
 * or the user presses refresh — never on a timer. Power (VCP 0xD6) is deliberately not offered.
 */
export const EXTERNAL_DISPLAY_DDC_STORAGE_KEY = "external_display_ddc_enabled";

export type DdcInvoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

export interface DdcStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface DdcInputSourceOption {
  readonly raw: number;
  readonly label: string;
}

export interface DdcDisplayMetadata {
  readonly id: string; readonly name: string; readonly manufacturer: string; readonly model: string; readonly isRedmiOrXiaomi: boolean;
  readonly brightnessPercent: number | null; readonly brightnessMax: number | null;
  readonly volumePercent: number | null; readonly volumeMax: number | null; readonly isMuted: boolean | null;
  readonly inputSource: number | null; readonly supportedInputSources: readonly number[];
  readonly supportsBrightness: boolean; readonly supportsVolume: boolean; readonly supportsMute: boolean; readonly supportsInputSource: boolean;
}

/** Matches `DDCCIInputSource` / `ddc_ci.rs::InputSource` raw values. */
export const DDC_INPUT_SOURCES: readonly DdcInputSourceOption[] = [
  { raw: 0x0f, label: "DP 1" },
  { raw: 0x10, label: "DP 2" },
  { raw: 0x11, label: "HDMI 1" },
  { raw: 0x12, label: "HDMI 2" },
  { raw: 0x1b, label: "USB-C" },
];

export function ddcInputSourceLabel(raw: number): string {
  return DDC_INPUT_SOURCES.find((o) => o.raw === raw)?.label ?? `0x${Math.max(0, Math.round(raw)).toString(16).toUpperCase().padStart(2, "0")}`;
}

interface DdcDisplayLocalState {
  brightness: number | null;
  volume: number | null;
  muted: boolean | null;
  input: number | null;
}

export interface DdcDisplayControllerDeps {
  readonly invoke?: DdcInvoke | null;
  readonly storage?: DdcStorage | null;
  readonly onChange?: () => void;
}

function defaultStorage(): DdcStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

function defaultInvoke(): DdcInvoke | null {
  const tauri = typeof window === "undefined" ? undefined : window.__TAURI_INTERNALS__;
  return tauri?.invoke ? (cmd, args) => tauri.invoke(cmd, args) : null;
}

function normalizeDisplayEntry(raw: unknown): DdcDisplayMetadata | null {
  if (typeof raw === "string") {
    return raw ? {
      id: raw, name: "", manufacturer: "", model: "", isRedmiOrXiaomi: false,
      brightnessPercent: null, brightnessMax: null, volumePercent: null, volumeMax: null, isMuted: null, inputSource: null,
      supportedInputSources: DDC_INPUT_SOURCES.map((o) => o.raw), supportsBrightness: true, supportsVolume: true, supportsMute: true, supportsInputSource: true,
    } : null;
  }
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.id !== "string" || !r.id) return null;
  const optPct = (v: unknown) => typeof v === "number" && Number.isFinite(v) ? clampPercent(v) : null;
  const optPos = (v: unknown) => typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.round(v) : null;
  const isU16 = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 0xffff;
  const supportedInputSources = Array.isArray(r.supportedInputSources) ? [...new Set(r.supportedInputSources.filter(isU16))] : [];
  const brightnessPercent = optPct(r.brightnessPercent), volumePercent = optPct(r.volumePercent);
  const isMuted = typeof r.isMuted === "boolean" ? r.isMuted : null;
  const supportsVolume = typeof r.supportsVolume === "boolean" ? r.supportsVolume : volumePercent !== null;
  return {
    id: r.id, name: typeof r.name === "string" ? r.name.trim() : "", manufacturer: typeof r.manufacturer === "string" ? r.manufacturer.trim() : "",
    model: typeof r.model === "string" ? r.model.trim() : "", isRedmiOrXiaomi: r.isRedmiOrXiaomi === true,
    brightnessPercent, brightnessMax: optPos(r.brightnessMax), volumePercent, volumeMax: optPos(r.volumeMax),
    isMuted, inputSource: isU16(r.inputSource) ? r.inputSource : null, supportedInputSources,
    supportsBrightness: typeof r.supportsBrightness === "boolean" ? r.supportsBrightness : brightnessPercent !== null,
    supportsVolume, supportsMute: typeof r.supportsMute === "boolean" ? r.supportsMute : supportsVolume || isMuted !== null,
    supportsInputSource: typeof r.supportsInputSource === "boolean" ? r.supportsInputSource && supportedInputSources.length > 0 : supportedInputSources.length > 0,
  };
}

export function friendlyDdcError(): string {
  return tr3(
    "显示器没有响应。请在显示器 OSD 菜单中开启 DDC/CI，或尝试 USB-C/DP 直连",
    "顯示器沒有回應。請在顯示器 OSD 選單中開啟 DDC/CI，或嘗試 USB-C/DP 直連",
    "The monitor didn't respond. Turn on DDC/CI in its on-screen menu, or connect over USB-C/DP",
  );
}

export class DdcDisplayController {
  private readonly storage: DdcStorage | null;
  private readonly invokeFn: DdcInvoke | null;
  onChange: () => void;
  private generation = 0;
  private refreshing: Promise<void> | null = null;
  private readonly pending = new Set<Promise<void>>();

  enabled: boolean;
  displays: DdcDisplayMetadata[] = [];
  scanned = false;
  error: string | null = null;
  readonly local = new Map<string, DdcDisplayLocalState>();

  constructor(deps: DdcDisplayControllerDeps = {}) {
    this.storage = deps.storage === undefined ? defaultStorage() : deps.storage;
    this.invokeFn = deps.invoke === undefined ? defaultInvoke() : deps.invoke;
    this.onChange = deps.onChange ?? (() => undefined);
    let stored: string | null = null;
    try {
      stored = this.storage?.getItem(EXTERNAL_DISPLAY_DDC_STORAGE_KEY) ?? null;
    } catch {
      stored = null;
    }
    this.enabled = stored === "true";
  }

  get isRefreshing(): boolean {
    return this.refreshing !== null;
  }

  get showsPanelCard(): boolean {
    return this.enabled && this.displays.length > 0;
  }

  setEnabled(enabled: boolean): void {
    if (enabled === this.enabled) return;
    this.enabled = enabled;
    try {
      this.storage?.setItem(EXTERNAL_DISPLAY_DDC_STORAGE_KEY, enabled ? "true" : "false");
    } catch {
      // Private mode / blocked storage: the switch still works for this session.
    }
    if (!enabled) {
      this.generation += 1;
      this.refreshing = null;
      this.displays = [];
      this.local.clear();
      this.scanned = false;
      this.error = null;
    }
    this.onChange();
  }

  /** Called when the panel is shown. A no-op while the feature is off. */
  onPanelShown(): void {
    if (!this.enabled || this.refreshing) return;
    void this.refresh();
  }

  refresh(): Promise<void> {
    if (!this.enabled) return Promise.resolve();
    if (this.refreshing) return this.refreshing;
    const invoke = this.invokeFn;
    if (!invoke) {
      this.scanned = true;
      this.error = tr3("当前环境不支持 DDC/CI 外接显示器控制", "目前環境不支援 DDC/CI 外接顯示器控制", "DDC/CI display control isn't available here");
      this.onChange();
      return Promise.resolve();
    }
    const token = this.generation;
    const run = (async () => {
      let nextDisplays: DdcDisplayMetadata[] = [];
      let failed = false;
      try {
        const result = await invoke("ddc_list_displays");
        nextDisplays = Array.isArray(result)
          ? result.map(normalizeDisplayEntry).filter((item): item is DdcDisplayMetadata => item !== null)
          : [];
      } catch {
        failed = true;
      }
      if (token !== this.generation) return;
      this.refreshing = null;
      this.scanned = true;
      this.displays = nextDisplays;
      const validIds = new Set(nextDisplays.map((d) => d.id));
      for (const id of [...this.local.keys()]) if (!validIds.has(id)) this.local.delete(id);
      for (const display of nextDisplays) {
        const prev = this.local.get(display.id);
        this.local.set(display.id, {
          brightness: display.brightnessPercent ?? prev?.brightness ?? null,
          volume: display.supportsVolume ? (display.volumePercent ?? prev?.volume ?? null) : null,
          muted: display.supportsMute ? (display.isMuted ?? prev?.muted ?? null) : null,
          input: display.inputSource ?? prev?.input ?? null,
        });
      }
      this.error = failed ? friendlyDdcError() : null;
      this.onChange();
    })();
    this.refreshing = run;
    this.onChange();
    return run;
  }

  displayById(id: string): DdcDisplayMetadata | undefined { return this.displays.find((d) => d.id === id); }
  stateFor(id: string): DdcDisplayLocalState {
    let state = this.local.get(id);
    if (!state) { state = { brightness: null, volume: null, muted: null, input: null }; this.local.set(id, state); }
    return state;
  }
  setBrightness(id: string, percent: number): Promise<void> {
    const value = clampPercent(percent);
    return this.write(id, (s) => (s.brightness = value), "ddc_set_brightness", { displayId: id, percent: value });
  }
  setVolume(id: string, percent: number): Promise<void> {
    if (!this.displayById(id)?.supportsVolume) return Promise.resolve();
    const value = clampPercent(percent);
    return this.write(id, (s) => (s.volume = value), "ddc_set_volume", { displayId: id, percent: value });
  }
  setInputSource(id: string, source: number): Promise<void> {
    const d = this.displayById(id);
    if (!d || !(d.supportedInputSources.length > 0 ? d.supportedInputSources.includes(source) : DDC_INPUT_SOURCES.some((o) => o.raw === source))) return Promise.resolve();
    return this.write(id, (s) => (s.input = source), "ddc_set_input_source", { displayId: id, source });
  }
  setMute(id: string, muted: boolean): Promise<void> {
    return this.displayById(id)?.supportsMute ? this.write(id, (s) => (s.muted = muted), "ddc_set_mute", { displayId: id, muted }) : Promise.resolve();
  }

  /** Lets tests wait for every in-flight IPC without sleeping. */
  async settle(): Promise<void> {
    while (this.refreshing || this.pending.size > 0) {
      await Promise.all([this.refreshing, ...this.pending]);
    }
  }

  private write(
    id: string,
    apply: (state: DdcDisplayLocalState) => void,
    cmd: string,
    args: Record<string, unknown>,
  ): Promise<void> {
    const invoke = this.invokeFn;
    if (!this.enabled || !invoke || !this.displayById(id)) return Promise.resolve();
    apply(this.stateFor(id));
    const token = this.generation;
    const task: Promise<void> = (async () => {
      let failed = false;
      try {
        await invoke(cmd, args);
      } catch {
        failed = true;
      }
      if (token !== this.generation) return;
      const nextError = failed ? friendlyDdcError() : null;
      if (nextError !== this.error) {
        this.error = nextError;
        this.onChange();
      }
    })();
    this.pending.add(task);
    void task.finally(() => this.pending.delete(task));
    return task;
  }
}

function clampPercent(value: number): number {
  return Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value))) : 0;
}

let sharedController: DdcDisplayController | null = null;

/** The app-wide controller; `onChange` is pointed at the host's `render`. */
export function getDdcDisplayController(): DdcDisplayController {
  sharedController ??= new DdcDisplayController();
  return sharedController;
}

type Escape = (raw: string) => string;

const displayTitle = (d: DdcDisplayMetadata, i: number) => d.name || tr3("外接显示器 {n}", "外接顯示器 {n}", "External Display {n}").replace("{n}", String(i + 1));
const renderXiaomiBadge = (esc: Escape) => `<span class="cc-ddc-badge" data-ddc-xiaomi-badge aria-label="${esc(tr3("已识别为小米/Redmi 显示器", "已識別為小米/Redmi 顯示器", "Recognized as a Xiaomi/Redmi monitor"))}">${esc(tr3("小米显示器", "小米顯示器", "Xiaomi"))}</span>`;

/** The panel card. Empty string while the feature is off or no display was found. */
export function renderDdcPanelSection(ctrl: DdcDisplayController, esc: Escape): string {
  if (!ctrl.showsPanelCard) return "";
  const cards = ctrl.displays.map((display, index) => renderDisplayCard(ctrl, display, index, esc)).join("");
  const error = ctrl.error
    ? `<p class="cc-ddc-error" role="status">${SF_ICONS.exclamationTriangleFill}<span>${esc(ctrl.error)}</span></p>`
    : "";
  return `<section class="cc-ddc-section" data-ddc-section aria-label="${esc(tr3("外接显示器", "外接顯示器", "External Displays"))}">${cards}${error}</section>`;
}

function renderDisplayCard(ctrl: DdcDisplayController, display: DdcDisplayMetadata, index: number, esc: Escape): string {
  const state = ctrl.local.get(display.id) ?? { brightness: display.brightnessPercent, volume: display.volumePercent, muted: display.isMuted, input: display.inputSource };
  const safeId = esc(display.id), brightness = state.brightness ?? 50, volume = state.volume ?? 50, muted = state.muted === true;
  const refresh = index === 0
    ? `<button type="button" class="cc-ddc-refresh${ctrl.isRefreshing ? " is-spinning" : ""}" data-ddc-refresh ${ctrl.isRefreshing ? "disabled" : ""}
        aria-label="${esc(tr3("刷新外接显示器", "重新整理外接顯示器", "Refresh external displays"))}" title="${esc(tr3("刷新外接显示器", "重新整理外接顯示器", "Refresh external displays"))}">${SF_ICONS.arrowClockwise}</button>`
    : "";
  const subtitle = state.input !== null
    ? tr3("外接显示器 · 当前 {source}", "外接顯示器 · 目前 {source}", "External display · on {source}").replace("{source}", ddcInputSourceLabel(state.input))
    : tr3("外接显示器 · DDC/CI", "外接顯示器 · DDC/CI", "External display · DDC/CI");
  const sliderGroup = (kind: "brightness" | "volume", value: number, label: string, icon: string) => `
      <div class="cc-slider-group">
        <div class="cc-slider-label"><span>${esc(label)}</span><strong data-ddc-${kind}-value="${safeId}">${state[kind] === null ? "—" : `${value}%`}</strong></div>
        ${renderLiquidGlassSlider({
          variant: "drawer", min: 0, max: 100, step: 1, value, formattedValue: `${value}%`, leadingIconSvg: icon, toneClass: "is-blue",
          inputDataAttrs: `data-ddc-${kind}="${safeId}"`, ariaAttrs: `aria-label="${esc(label)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${value}" aria-valuetext="${value}%"`,
        })}
      </div>`;
  const brightnessBlock = display.supportsBrightness ? sliderGroup("brightness", brightness, tr3("亮度", "亮度", "Brightness"), SF_ICONS.sunMaxFill) : "";
  const inputsBlock = display.supportsInputSource && display.supportedInputSources.length > 0
    ? `<div class="cc-segmented-pills cc-ddc-inputs" role="group" aria-label="${esc(tr3("输入源", "輸入來源", "Input Source"))}">${
        display.supportedInputSources.map((raw) => {
          const active = state.input === raw;
          return `<button type="button" class="cc-seg-pill${active ? " is-active" : ""}" data-ddc-input="${safeId}" data-ddc-source="${raw}" aria-pressed="${active}">${esc(ddcInputSourceLabel(raw))}</button>`;
        }).join("")}</div>`
    : "";
  const muteButton = display.supportsMute
    ? `<button type="button" class="cc-ddc-mute${muted ? " is-active" : ""}" data-ddc-mute="${safeId}" aria-pressed="${muted}" aria-label="${esc(muted ? tr3("取消静音", "取消靜音", "Unmute") : tr3("静音", "靜音", "Mute"))}">${muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerFill}</button>`
    : "";
  const volumeBlock = display.supportsVolume ? `<div class="cc-ddc-volume-row">${sliderGroup("volume", volume, tr3("音量", "音量", "Volume"), muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave)}${muteButton}</div>` : "";
  return `
    <article class="cc-ddc-card" data-ddc-display="${safeId}">
      <header class="cc-ddc-header">
        <span class="cc-ddc-icon" aria-hidden="true">${SF_ICONS.sliderHorizontal}</span>
        <div class="cc-ddc-title">
          <div class="cc-ddc-title-row"><strong>${esc(displayTitle(display, index))}</strong>${display.isRedmiOrXiaomi ? renderXiaomiBadge(esc) : ""}</div>
          <span>${esc(subtitle)}</span>
        </div>
        ${refresh}
      </header>
      ${brightnessBlock}${inputsBlock}${volumeBlock}
    </article>`;
}

/** Settings → 常规 card: the off-by-default switch, the safety notes and a scan button. */
export function renderDdcSettingsSection(ctrl: DdcDisplayController, esc: Escape): string {
  const title = tr3("外接显示器控制（DDC/CI）", "外接顯示器控制（DDC/CI）", "External Display Control (DDC/CI)");
  const hint = tr3(
    "支持 Redmi G27U 等外接显示器的亮度、音量与 DP/HDMI/USB-C 输入源切换。未开启时零后台开销；为保护显示器固件、避免假死，刻意不提供电源关屏（0xD6）。若无法控制，请在显示器 OSD 中开启 DDC/CI，或改用 USB-C/DP 线缆。",
    "支援 Redmi G27U 等外接顯示器的亮度、音量與 DP/HDMI/USB-C 輸入來源切換。未開啟時零背景開銷；為保護顯示器韌體、避免當機，刻意不提供電源關閉（0xD6）。若無法控制，請在顯示器 OSD 中開啟 DDC/CI，或改用 USB-C/DP 線材。",
    "Adjust brightness, volume and DP/HDMI/USB-C input on monitors such as the Redmi G27U. Nothing runs in the background while this is off. Power-off (0xD6) is deliberately not offered to protect monitor firmware from hanging. If control fails, turn on DDC/CI in the monitor's menu or use a USB-C/DP cable.",
  );
  let summary = "";
  if (ctrl.enabled) {
    const status = ctrl.error
      ? ctrl.error
      : ctrl.isRefreshing
        ? tr3("正在扫描…", "正在掃描…", "Scanning…")
        : !ctrl.scanned
          ? tr3("点击扫描以检测外接显示器", "點擊掃描以偵測外接顯示器", "Scan to detect external displays")
          : ctrl.displays.length === 0
            ? tr3("未检测到外接显示器", "未偵測到外接顯示器", "No external display detected")
            : tr3("已检测到 {n} 台显示器", "已偵測到 {n} 台顯示器", "{n} display(s) detected").replace("{n}", String(ctrl.displays.length));
    const displayRows = ctrl.displays.length > 0
      ? `<ul class="cc-ddc-settings-list" style="list-style: none; margin: 6px 0 0 0; padding: 0;">${
          ctrl.displays.map((display, index) => {
            const state = ctrl.local.get(display.id), parts: string[] = [];
            const brightness = state?.brightness ?? display.brightnessPercent, input = state?.input ?? display.inputSource;
            if (brightness !== null) parts.push(tr3("亮度 {v}%", "亮度 {v}%", "Brightness {v}%").replace("{v}", String(brightness)));
            if (input !== null) parts.push(ddcInputSourceLabel(input));
            return `<li class="cc-field-row" data-ddc-settings-row="${esc(display.id)}"><span class="cc-ddc-title-row"><span>${esc(displayTitle(display, index))}</span>${display.isRedmiOrXiaomi ? renderXiaomiBadge(esc) : ""}</span><span class="cc-field-hint" style="margin: 0;">${esc(parts.join(" · ") || tr3("已连接", "已連線", "Connected"))}</span></li>`;
          }).join("")}</ul>`
      : "";
    summary = `
        ${displayRows}
        <div class="cc-field-row" style="margin-top: 6px;">
          <p class="cc-field-hint" data-ddc-settings-status style="margin: 0;">${esc(status)}</p>
          <button type="button" class="cc-btn-secondary" data-ddc-scan ${ctrl.isRefreshing ? "disabled" : ""}>${esc(tr3("扫描外接显示器", "掃描外接顯示器", "Scan External Displays"))}</button>
        </div>`;
  }
  return `
    <div class="cc-settings-group-card" data-ddc-settings>
      <div class="cc-field" data-settings-anchor="externalDisplayDdc">
        <div class="cc-field-row">
          <div>
            <label for="settings-external-display-ddc">${esc(title)}</label>
            <p class="cc-field-hint" style="margin: 2px 0 0 0;">${esc(hint)}</p>
          </div>
          <input id="settings-external-display-ddc" type="checkbox" data-ddc-toggle ${ctrl.enabled ? "checked" : ""} />
        </div>${summary}
      </div>
    </div>`;
}

const boundRoots = new WeakSet<HTMLElement>();

/** Delegated listeners on the app root; safe to call after every render. */
export function bindDdcDisplayEvents(root: HTMLElement, ctrl: DdcDisplayController): void {
  if (boundRoots.has(root)) return;
  boundRoots.add(root);
  root.addEventListener("click", (event) => {
    const target = (event.target as Element | null)?.closest<HTMLElement>("[data-ddc-refresh], [data-ddc-scan], [data-ddc-input], [data-ddc-mute]");
    if (!target || !root.contains(target)) return;
    if (target.matches("[data-ddc-refresh], [data-ddc-scan]")) {
      void ctrl.refresh();
    } else if (target.dataset.ddcInput) {
      void ctrl.setInputSource(target.dataset.ddcInput, Number(target.dataset.ddcSource));
      ctrl.onChange();
    } else if (target.dataset.ddcMute) {
      const id = target.dataset.ddcMute;
      void ctrl.setMute(id, ctrl.local.get(id)?.muted !== true);
      ctrl.onChange();
    }
  });
  root.addEventListener("input", (event) => {
    const input = event.target as HTMLInputElement | null;
    const id = input?.dataset.ddcBrightness ?? input?.dataset.ddcVolume;
    if (!input || !id) return;
    const kind = input.dataset.ddcBrightness !== undefined ? "brightness" : "volume";
    const label = root.querySelector<HTMLElement>(`[data-ddc-${kind}-value="${CSS.escape(id)}"]`);
    if (label) label.textContent = `${Math.round(Number(input.value))}%`;
  });
  // Write once per drag, on release, so a slider never floods the monitor's I²C bus.
  root.addEventListener("change", (event) => {
    const input = event.target as HTMLInputElement | null;
    if (!input) return;
    if (input.matches("[data-ddc-toggle]")) {
      ctrl.setEnabled(input.checked);
      if (input.checked) void ctrl.refresh();
      return;
    }
    if (input.dataset.ddcBrightness) void ctrl.setBrightness(input.dataset.ddcBrightness, Number(input.value));
    else if (input.dataset.ddcVolume) void ctrl.setVolume(input.dataset.ddcVolume, Number(input.value));
  });
}
