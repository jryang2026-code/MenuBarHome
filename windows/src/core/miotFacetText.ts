import { speechLocale, t } from "./i18n.js";
import { formatTemperature } from "./temperature.js";
import { deviceTypeLabel, deviceTypeSymbolName, facetLabel, familyFacetLabel } from "./deviceLabels.js";
import type { FacetControl } from "./models.js";

/**
 * Display text for a generic facet, shared by the generic card's readouts and the 更多设置 drawer
 * (#5, #6), so the card and the drawer cannot format the same value differently. Mirrors macOS
 * `MiotFacetText`.
 *
 * The Chinese titles and their English column live in `Shared/deviceLabels.json` (#11); this module
 * only picks which one a row shows.
 */

export function humanizedFacetName(raw: string): string {
  const words = raw.replaceAll("-", " ");
  const first = words.slice(0, 1);
  return first.toUpperCase() + words.slice(1);
}

/** Row title: a known MIoT name, else the spec's own description, else the humanized name. */
export function facetTitle(control: FacetControl): string {
  const known = facetLabel(control.name);
  if (known) return speechLocale() === "en-US" ? known.en : t(known["zh-Hans"]);
  const family = familyFacetLabel(control.name);
  if (family && speechLocale() !== "en-US") return family["zh-Hans"];
  const raw = (control.title ?? "").trim();
  return raw.length > 0 ? raw : humanizedFacetName(control.name);
}

export function facetAlertText(control: FacetControl, label: string): string {
  const title = facetTitle(control);
  if (speechLocale() === "en-US") return `${title}：${label}`;
  const key = label.toLowerCase();
  let condition: string | undefined;
  if (key.includes("upper limit")) condition = "高于上限";
  else if (key.includes("lower limit")) condition = "低于下限";
  else if (control.name.includes("pump")) {
    condition = {
      "not inserted": "未插入", low: "低水位", low1: "低水位",
      blocked: "堵塞", blockage: "堵塞", bockage: "堵塞", fault: "故障",
    }[key];
  } else if (["food", "feed", "left-level"].some((word) => control.name.includes(word))) {
    condition = { empty: "已空", low: "余粮不足", "stuck food": "卡粮", timeout: "超时" }[key];
  }
  condition ??= {
    fault: "故障", error: "错误", exception: "异常", alarm: "告警",
    change: "需更换", timeout: "超时", empty: "已空", offline: "离线",
    "not inserted": "未插入", blocked: "堵塞", blockage: "堵塞", bockage: "堵塞",
  }[key];
  return `${title}：${condition ?? label}`;
}

function unitSuffix(unit: string | null): string {
  const trimmed = (unit ?? "").trim();
  if (!trimmed || trimmed.toLowerCase() === "none") return "";
  switch (trimmed.toLowerCase()) {
    case "celsius":
      return " °C";
    case "percentage":
    case "percent":
      return "%";
    case "ppm":
      return " ppm";
    case "lux":
      return " lx";
    case "minutes":
      return " min";
    case "seconds":
      return " s";
    case "hour":
    case "hours":
      return " h";
    default:
      return ` ${trimmed}`;
  }
}

/** A whole number reads as an integer; a fractional step keeps one decimal. */
export function formatReading(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/** The value a row shows: an option label, 开/关, a scaled reading, or the raw value. */
export function facetValue(control: FacetControl): string {
  let raw = control.value;
  if (
    typeof raw === "string" &&
    raw.trim() !== "" &&
    (control.options.length > 0 ||
      control.kind === "slider" ||
      control.kind === "toggle" ||
      control.scale !== null ||
      control.unit !== null)
  ) {
    const trimmed = raw.trim().toLowerCase();
    if (control.kind === "toggle" && (trimmed === "true" || trimmed === "false")) {
      raw = trimmed === "true";
    } else {
      const parsed = Number(trimmed);
      if (Number.isFinite(parsed)) raw = parsed;
    }
  }
  if (typeof raw === "number") {
    const option = control.options.find((item) => item.value === Math.trunc(raw));
    if (option) return option.label;
  }
  if (control.kind === "toggle") return raw === true || raw === 1 ? t("开") : t("关");
  if (typeof raw === "number") {
    const scaled = raw * (control.scale ?? 1);
    if (control.kind === "reading" && control.unit?.toLowerCase() === "celsius") {
      return formatTemperature(scaled, undefined, 1);
    }
    return formatReading(scaled) + unitSuffix(control.unit);
  }
  if (typeof raw === "boolean") return raw ? t("开") : t("关");
  if (typeof raw === "string" && raw.length > 0) return raw;
  return "—";
}

/** Device-type label for a generic card. */
export function genericTypeTitle(deviceType: string): string {
  // English keeps the catalog lookup: most device types have no English entry yet, and the shared
  // file's `en` column is staged for the follow-up that lands those titles (#11).
  const known = deviceTypeLabel(deviceType)?.["zh-Hans"];
  return known ? t(known) : humanizedFacetName(deviceType);
}

/** A symbol name in the macOS vocabulary, so both cards pick the same glyph. */
export function genericSymbolName(deviceType: string): string {
  return deviceTypeSymbolName(deviceType);
}
