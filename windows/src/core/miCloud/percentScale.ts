import type { MiotProperty } from "./spec.js";

/**
 * The one conversion between a MIoT property's raw value and the card's 0…100 percent, mirroring
 * macOS `MiotPercentScale`. Synthesis decodes with it and the command mapper encodes with it, so a
 * percent read off a card writes back the raw value it came from.
 *
 * `proportional`: `raw / max` unless the range already ends at 100 (brightness, volume, position).
 * `speed`: a fan range or level list starting above 1 maps its low end to 0 %.
 */
export type PercentCurve = "proportional" | "speed";

function speedBounds(prop: MiotProperty): { lo: number; hi: number } | null {
  const range = prop.valueRange;
  if (range && range.length >= 2) {
    const lo = range[0];
    const hi = range[1];
    if (lo !== undefined && hi !== undefined && Number.isFinite(lo) && Number.isFinite(hi) && hi > lo) {
      return { lo, hi };
    }
  }
  const list = prop.valueList;
  if (list && list.length > 0) {
    const vals = list.map((i) => i.value).filter((v) => Number.isFinite(v));
    if (vals.length > 0) {
      const lo = Math.min(...vals);
      const hi = Math.max(...vals);
      if (Number.isFinite(lo) && Number.isFinite(hi) && hi > lo) return { lo, hi };
    }
  }
  return null;
}

function proportionalMax(prop: MiotProperty): number | null {
  const max = prop.valueRange?.[1];
  return max !== undefined && Number.isFinite(max) && max > 0 && max !== 100 ? max : null;
}

export function percentFromRaw(raw: number, prop: MiotProperty, curve: PercentCurve): number {
  if (!Number.isFinite(raw)) return 0;
  let scaled: number;
  const bounds = curve === "speed" ? speedBounds(prop) : null;
  if (bounds) {
    const { lo, hi } = bounds;
    scaled = lo > 1 ? ((raw - lo) / (hi - lo)) * 100 : hi !== 100 ? (raw / hi) * 100 : raw;
  } else {
    const max = proportionalMax(prop);
    scaled = max !== null ? (raw / max) * 100 : raw;
  }
  if (!Number.isFinite(scaled)) return 0;
  return Math.max(0, Math.min(100, Math.round(scaled)));
}

/** The raw value for `percent`, snapped to the nearest level for a value-list speed property. */
export function rawFromPercent(percent: number, prop: MiotProperty, curve: PercentCurve): number {
  const safePercent = Number.isFinite(percent) ? Math.max(0, Math.min(100, percent)) : 0;
  const p = safePercent / 100;
  if (curve === "speed") {
    const lo0 = prop.valueRange?.[0];
    const hi0 = prop.valueRange?.[1];
    const hasRange =
      prop.valueRange !== undefined &&
      prop.valueRange.length >= 2 &&
      lo0 !== undefined &&
      hi0 !== undefined &&
      Number.isFinite(lo0) &&
      Number.isFinite(hi0) &&
      hi0 > lo0;
    const list = prop.valueList;
    const bounds = speedBounds(prop);
    if (!hasRange && list && list.length > 0) {
      const fallbackVal = Number.isFinite(list[0]!.value) ? list[0]!.value : 0;
      if (!bounds) return fallbackVal;
      const target = bounds.lo > 1 ? bounds.lo + p * (bounds.hi - bounds.lo) : p * bounds.hi;
      let best = list[0]!;
      for (const item of list) {
        if (!Number.isFinite(item.value)) continue;
        if (!Number.isFinite(best.value) || Math.abs(item.value - target) < Math.abs(best.value - target)) {
          best = item;
        }
      }
      return Number.isFinite(best.value) ? best.value : fallbackVal;
    }
    if (bounds) {
      const { lo, hi } = bounds;
      const out = lo > 1 ? lo + p * (hi - lo) : hi !== 100 ? p * hi : p * 100;
      return Number.isFinite(out) ? out : 0;
    }
  }
  const max = proportionalMax(prop);
  const out = max !== null ? p * max : p * 100;
  return Number.isFinite(out) ? out : 0;
}
