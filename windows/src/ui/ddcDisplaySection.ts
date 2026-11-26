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

/** Matches `DDCCIInputSource` / `ddc_ci.rs::InputSource` raw values. */
export const DDC_INPUT_SOURCES: readonly DdcInputSourceOption[] = [
  { raw: 0x0f, label: "DP 1" },
  { raw: 0x10, label: "DP 2" },
  { raw: 0x11, label: "HDMI 1" },
  { raw: 0x12, label: "HDMI 2" },
  { raw: 0x1b, label: "USB-C" },
];

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
  displays: string[] = [];
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
      let ids: string[] = [];
      let failed = false;
      try {
        const result = await invoke("ddc_list_displays");
        ids = Array.isArray(result) ? result.filter((x): x is string => typeof x === "string") : [];
      } catch {
        failed = true;
      }
      if (token !== this.generation) return;
      this.refreshing = null;
      this.scanned = true;
      this.displays = ids;
      for (const id of [...this.local.keys()]) if (!ids.includes(id)) this.local.delete(id);
      this.error = failed ? friendlyDdcError() : null;
      this.onChange();
    })();
    this.refreshing = run;
    this.onChange();
    return run;
  }

  stateFor(id: string): DdcDisplayLocalState {
    let state = this.local.get(id);
    if (!state) {
      state = { brightness: null, volume: null, muted: null, input: null };
      this.local.set(id, state);
    }
    return state;
  }

  setBrightness(id: string, percent: number): Promise<void> {
    const value = clampPercent(percent);
    return this.write(id, (s) => (s.brightness = value), "ddc_set_brightness", { displayId: id, percent: value });
  }

  setVolume(id: string, percent: number): Promise<void> {
    const value = clampPercent(percent);
    return this.write(id, (s) => (s.volume = value), "ddc_set_volume", { displayId: id, percent: value });
  }

  setInputSource(id: string, source: number): Promise<void> {
    if (!DDC_INPUT_SOURCES.some((option) => option.raw === source)) return Promise.resolve();
    return this.write(id, (s) => (s.input = source), "ddc_set_input_source", { displayId: id, source });
  }

  setMute(id: string, muted: boolean): Promise<void> {
    return this.write(id, (s) => (s.muted = muted), "ddc_set_mute", { displayId: id, muted });
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
    if (!this.enabled || !invoke || !this.displays.includes(id)) return Promise.resolve();
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

function displayLabel(index: number): string {
  return tr3("外接显示器 {n}", "外接顯示器 {n}", "External Display {n}").replace("{n}", String(index + 1));
}

/** The panel card. Empty string while the feature is off or no display was found. */
export function renderDdcPanelSection(ctrl: DdcDisplayController, esc: Escape): string {
  if (!ctrl.showsPanelCard) return "";
  const cards = ctrl.displays.map((id, index) => renderDisplayCard(ctrl, id, index, esc)).join("");
  const error = ctrl.error
    ? `<p class="cc-ddc-error" role="status">${SF_ICONS.exclamationTriangleFill}<span>${esc(ctrl.error)}</span></p>`
    : "";
  return `<section class="cc-ddc-section" data-ddc-section aria-label="${esc(tr3("外接显示器", "外接顯示器", "External Displays"))}">${cards}${error}</section>`;
}

function renderDisplayCard(ctrl: DdcDisplayController, id: string, index: number, esc: Escape): string {
  const state = ctrl.local.get(id) ?? { brightness: null, volume: null, muted: null, input: null };
  const safeId = esc(id);
  const brightness = state.brightness ?? 50;
  const volume = state.volume ?? 50;
  const muted = state.muted === true;
  const refresh = index === 0
    ? `<button type="button" class="cc-ddc-refresh${ctrl.isRefreshing ? " is-spinning" : ""}" data-ddc-refresh ${ctrl.isRefreshing ? "disabled" : ""}
        aria-label="${esc(tr3("刷新外接显示器", "重新整理外接顯示器", "Refresh external displays"))}" title="${esc(tr3("刷新外接显示器", "重新整理外接顯示器", "Refresh external displays"))}">${SF_ICONS.arrowClockwise}</button>`
    : "";
  const inputs = DDC_INPUT_SOURCES.map((option) => {
    const active = state.input === option.raw;
    return `<button type="button" class="cc-seg-pill${active ? " is-active" : ""}" data-ddc-input="${safeId}" data-ddc-source="${option.raw}" aria-pressed="${active}">${esc(option.label)}</button>`;
  }).join("");
  const sliderGroup = (kind: "brightness" | "volume", value: number, label: string, icon: string) => `
      <div class="cc-slider-group">
        <div class="cc-slider-label"><span>${esc(label)}</span><strong data-ddc-${kind}-value="${safeId}">${state[kind] === null ? "—" : `${value}%`}</strong></div>
        ${renderLiquidGlassSlider({
          variant: "drawer",
          min: 0,
          max: 100,
          step: 1,
          value,
          formattedValue: `${value}%`,
          leadingIconSvg: icon,
          toneClass: "is-blue",
          inputDataAttrs: `data-ddc-${kind}="${safeId}"`,
          ariaAttrs: `aria-label="${esc(label)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${value}" aria-valuetext="${value}%"`,
        })}
      </div>`;
  return `
    <article class="cc-ddc-card" data-ddc-display="${safeId}">
      <header class="cc-ddc-header">
        <span class="cc-ddc-icon" aria-hidden="true">${SF_ICONS.sliderHorizontal}</span>
        <div class="cc-ddc-title">
          <strong>${esc(displayLabel(index))}</strong>
          <span>DDC/CI</span>
        </div>
        ${refresh}
      </header>
      ${sliderGroup("brightness", brightness, tr3("亮度", "亮度", "Brightness"), SF_ICONS.sunMaxFill)}
      <div class="cc-segmented-pills cc-ddc-inputs" role="group" aria-label="${esc(tr3("输入源", "輸入來源", "Input Source"))}">${inputs}</div>
      <div class="cc-ddc-volume-row">
        ${sliderGroup("volume", volume, tr3("音量", "音量", "Volume"), muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave)}
        <button type="button" class="cc-ddc-mute${muted ? " is-active" : ""}" data-ddc-mute="${safeId}" aria-pressed="${muted}"
          aria-label="${esc(muted ? tr3("取消静音", "取消靜音", "Unmute") : tr3("静音", "靜音", "Mute"))}">${muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerFill}</button>
      </div>
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
    summary = `
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
