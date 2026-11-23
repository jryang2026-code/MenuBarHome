/**
 * The facet and device-type labels both platforms show (#11), read from
 * `Shared/deviceLabels.json`. macOS ships a byte-identical copy in
 * `Sources/MijiaCore/Resources/` and loads it through `DeviceLabels.swift`.
 *
 * The document only carries strings and neutral icon ids — no expressions and no platform glyphs.
 * English is stored beside the Chinese text, matching the inline catalog shape of `i18n.ts`;
 * Traditional Chinese stays in `zhHantCatalog.ts`, keyed by the Simplified text, so `t()` keeps
 * answering it exactly as before.
 *
 * `facetTitles` and `familyFacetTitles` mirror the two groups the Windows card already had: the
 * main group is translated through `t()`, and the water-pump/feeder/filter family group has no
 * English label yet, so it falls back to the spec's own description in English.
 */
import sharedLabelsJson from "../../../Shared/deviceLabels.json";
import { DEFAULT_DEVICE_ICON_SYMBOL, DEVICE_ICON_SYMBOLS } from "./deviceIconSymbols.js";

/** One label in the two languages the inline catalogs carry. */
export interface DeviceLabelTitle {
  readonly "zh-Hans": string;
  readonly en: string;
}

/** A device type's label and semantic icon id. `chair` and `bike` only carry an icon. */
export interface DeviceTypeLabel {
  readonly "zh-Hans"?: string;
  readonly en?: string;
  readonly icon?: string;
}

export interface DeviceLabelsDocument {
  readonly schemaVersion: number;
  readonly defaultIcon: string;
  readonly facetTitles: Readonly<Record<string, DeviceLabelTitle>>;
  readonly familyFacetTitles: Readonly<Record<string, DeviceLabelTitle>>;
  readonly deviceTypes: Readonly<Record<string, DeviceTypeLabel>>;
}

/** The one shared document, as imported at build time. */
export const DEVICE_LABELS: DeviceLabelsDocument = sharedLabelsJson;

export function facetLabel(name: string): DeviceLabelTitle | undefined {
  return DEVICE_LABELS.facetTitles[name];
}

export function familyFacetLabel(name: string): DeviceLabelTitle | undefined {
  return DEVICE_LABELS.familyFacetTitles[name];
}

export function deviceTypeLabel(deviceType: string): DeviceTypeLabel | undefined {
  return DEVICE_LABELS.deviceTypes[deviceType];
}

/**
 * The card symbol for a device type: its neutral icon id mapped to the Windows vocabulary, or the
 * document's default icon for a type it does not list.
 */
export function deviceTypeSymbolName(deviceType: string): string {
  const icon = deviceTypeLabel(deviceType)?.icon ?? DEVICE_LABELS.defaultIcon;
  return DEVICE_ICON_SYMBOLS[icon] ?? DEFAULT_DEVICE_ICON_SYMBOL;
}
