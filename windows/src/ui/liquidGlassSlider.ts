export interface LiquidGlassSliderSpec {
  readonly variant: "inline" | "drawer";
  readonly min: number;
  readonly max: number;
  readonly step: number | null;
  readonly value: number;
  readonly formattedValue: string;
  readonly leadingIconSvg?: string;
  readonly toneClass?: string;
  readonly isSpectrumTrack?: boolean;
  readonly allowOffGridMax?: boolean;
  readonly showDecileTicks?: boolean;
  readonly inputClassName?: string;
  readonly inputDataAttrs: string;
  readonly ariaAttrs: string;
  readonly disabledAttr?: string;
}

const round6 = (v: number): number => Number(v.toFixed(6));
export const formatSliderAttrNumber = (n: number): string => (Number.isInteger(n) ? String(n) : String(round6(n)));

export const SliderStepSnap = {
  snap(raw: number, min: number, max: number, step: number | null, allowOffGridMax = false): number {
    const clamped = Math.min(max, Math.max(min, raw));
    const span = max - min;
    if (step === null || !Number.isFinite(step) || step <= 0 || span <= 0) return round6(clamped);
    const lastGrid = min + Math.floor(span / step) * step;
    if (clamped > lastGrid) {
      if (!allowOffGridMax) return round6(Math.max(min, lastGrid));
      return round6(clamped >= lastGrid + (max - lastGrid) * 0.5 ? max : lastGrid);
    }
    return round6(Math.min(max, Math.max(min, min + Math.round((clamped - min) / step) * step)));
  },
  stepBy(value: number, delta: number, min: number, max: number, step: number, allowOffGridMax = false): number {
    const clamped = Math.min(max, Math.max(min, value));
    const span = max - min;
    if (step > 0 && span > 0 && delta < 0) {
      const lastGrid = min + Math.floor(span / step) * step;
      if (clamped > lastGrid) return round6(Math.max(min, lastGrid));
    }
    return this.snap(clamped + delta, min, max, step, allowOffGridMax);
  },
  decileBucket(value: number, min: number, max: number): number {
    const span = max - min;
    return span <= 0 ? 0 : Math.floor(((Math.min(max, Math.max(min, value)) - min) / span) * 10);
  },
} as const;

export function renderLiquidGlassSlider(spec: LiquidGlassSliderSpec): string {
  const allowOffGridMax = Boolean(spec.allowOffGridMax);
  const snapped = SliderStepSnap.snap(spec.value, spec.min, spec.max, spec.step, allowOffGridMax);
  const span = spec.max - spec.min;
  const ratio = span > 0 ? Math.max(0, Math.min(1, (snapped - spec.min) / span)) : 0;
  const ratioStr = ratio.toFixed(4);
  const pctStr = (ratio * 100).toFixed(2);
  const activeDecile = SliderStepSnap.decileBucket(snapped, spec.min, spec.max);
  const ticksHtml = spec.showDecileTicks
    ? [1, 2, 3, 4, 5, 6, 7, 8, 9]
        .map((d) => `<span class="cc-liquid-tick" data-tick-decile="${d}" data-tick-active="${d <= activeDecile ? "true" : "false"}" style="left:${d * 10}%"></span>`)
        .join("")
    : "";
  const hasStep = spec.step !== null && Number.isFinite(spec.step) && spec.step > 0;
  const stepDivides = hasStep && span > 0 && Math.abs(span / spec.step! - Math.round(span / spec.step!)) < 1e-6;
  const domStepAttr = hasStep
    ? ` step="${!allowOffGridMax || stepDivides ? formatSliderAttrNumber(spec.step!) : "1"}"`
    : "";
  const snapStepAttr = hasStep ? ` data-snap-step="${formatSliderAttrNumber(spec.step!)}"` : "";
  const offGridAttr = allowOffGridMax ? ' data-allow-off-grid-max="true"' : "";
  const wrapCls = ["cc-liquid-slider", `is-${spec.variant}`, spec.isSpectrumTrack ? "is-kelvin" : "", spec.toneClass ?? ""].filter(Boolean).join(" ");
  const inputCls = ["cc-range", spec.inputClassName ?? "", spec.toneClass ?? ""].filter(Boolean).join(" ");
  return `<div class="${wrapCls}" data-liquid-slider="${spec.variant}" style="--slider-ratio:${ratioStr};--fill-scale:${ratioStr}"><div class="cc-liquid-track" aria-hidden="true"><span class="cc-liquid-fill" style="--fill-scale:${ratioStr}"></span>${ticksHtml}<span class="cc-liquid-thumb"></span><div class="cc-liquid-chrome">${spec.leadingIconSvg ? `<span class="cc-liquid-icon">${spec.leadingIconSvg}</span>` : ""}<span class="cc-liquid-readout">${spec.formattedValue}</span></div></div><span class="cc-slider-thumb-badge" aria-hidden="true"></span><input class="${inputCls}" type="range" min="${formatSliderAttrNumber(spec.min)}" max="${formatSliderAttrNumber(spec.max)}"${domStepAttr} value="${formatSliderAttrNumber(snapped)}"${snapStepAttr}${offGridAttr} style="--val:${pctStr}%" ${spec.inputDataAttrs} ${spec.ariaAttrs}${spec.disabledAttr ?? ""} /></div>`;
}

export function syncLiquidGlassSlider(slider: HTMLInputElement, formattedOverride?: string): number {
  const min = Number(slider.min || "0");
  const max = Number(slider.max || "100");
  const snapAttr = slider.getAttribute("data-snap-step");
  const snapStep = snapAttr ? Number(snapAttr) : slider.step && slider.step !== "any" ? Number(slider.step) : null;
  const allowOffGridMax = slider.getAttribute("data-allow-off-grid-max") === "true";
  const raw = Number(slider.value || "0");
  const val = SliderStepSnap.snap(Number.isFinite(raw) ? raw : min, min, max, snapStep, allowOffGridMax);
  const valStr = formatSliderAttrNumber(val);
  if (slider.value !== valStr) slider.value = valStr;
  const span = max - min;
  const ratio = span > 0 ? Math.max(0, Math.min(1, (val - min) / span)) : 0;
  const ratioStr = ratio.toFixed(4);
  slider.style.setProperty("--val", `${(ratio * 100).toFixed(2)}%`);
  const wrap = slider.closest<HTMLElement>(".cc-liquid-slider");
  if (!wrap) return val;
  wrap.style.setProperty("--slider-ratio", ratioStr);
  wrap.style.setProperty("--fill-scale", ratioStr);
  wrap.querySelector<HTMLElement>(".cc-liquid-fill")?.style.setProperty("--fill-scale", ratioStr);
  const activeDecile = SliderStepSnap.decileBucket(val, min, max);
  wrap.querySelectorAll<HTMLElement>(".cc-liquid-tick").forEach((tick) => {
    tick.setAttribute("data-tick-active", Number(tick.dataset.tickDecile || "0") <= activeDecile ? "true" : "false");
  });
  const readout = wrap.querySelector<HTMLElement>(".cc-liquid-readout");
  if (readout) {
    const ariaText = slider.getAttribute("aria-valuetext");
    readout.textContent = formattedOverride || (slider.dataset.colortemp !== undefined ? `${Math.round(val)}K` : ariaText || `${Math.round(val)}%`);
  }
  return val;
}

export function bindLiquidGlassSliders(scope: ParentNode): void {
  const clearDragging = (): void => {
    scope.querySelectorAll<HTMLElement>(".cc-liquid-slider.is-dragging").forEach((el) => el.classList.remove("is-dragging"));
  };
  scope.querySelectorAll<HTMLInputElement>(".cc-liquid-slider input.cc-range").forEach((slider) => {
    syncLiquidGlassSlider(slider);
    const wrap = slider.closest<HTMLElement>(".cc-liquid-slider");
    const onDrag = (): void => {
      clearDragging();
      wrap?.classList.add("is-dragging");
      syncLiquidGlassSlider(slider);
    };
    const onRelease = (): void => {
      wrap?.classList.remove("is-dragging");
      syncLiquidGlassSlider(slider);
    };
    slider.addEventListener("pointerdown", onDrag, { capture: true });
    slider.addEventListener("input", onDrag, { capture: true });
    slider.addEventListener("change", onRelease, { capture: true });
    slider.addEventListener("pointerup", onRelease);
    slider.addEventListener("pointercancel", onRelease);
    slider.addEventListener("blur", onRelease);
    slider.addEventListener("keydown", (e) => {
      const step = Number(slider.getAttribute("data-snap-step") || "0");
      if (!Number.isFinite(step) || step <= 0) return;
      if (e.key !== "ArrowRight" && e.key !== "ArrowUp" && e.key !== "ArrowLeft" && e.key !== "ArrowDown") return;
      e.preventDefault();
      const min = Number(slider.min || "0");
      const max = Number(slider.max || "100");
      const dir = e.key === "ArrowRight" || e.key === "ArrowUp" ? 1 : -1;
      slider.value = formatSliderAttrNumber(SliderStepSnap.stepBy(Number(slider.value || "0"), dir * step, min, max, step));
      syncLiquidGlassSlider(slider);
      slider.dispatchEvent(new Event("input", { bubbles: true }));
      slider.dispatchEvent(new Event("change", { bubbles: true }));
    });
  });
}
