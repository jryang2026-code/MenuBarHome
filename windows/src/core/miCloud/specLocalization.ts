/**
 * Official MIoT `instance/v2/multiLanguage` document support, mirrored by
 * `Sources/MijiaCore/MiCloud/MiotSpecLocalization.swift`.
 *
 * Endpoint keys are `service:<siid>`, `service:<siid>:property:<piid>` and
 * `service:<siid>:property:<piid>:valuelist:<index>`. The suffix is the 0-based position in the
 * spec's `value-list`, not the property value. Patches are applied by the caller after this step.
 */
import type { AppLanguage } from "../i18n.js";
import type { MiotDeviceSpec, MiotValueListItem } from "./spec.js";

export const MULTI_LANGUAGE_CACHE_VERSION = 1;
export const MULTI_LANGUAGE_CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export interface SpecMultiLanguage {
  readonly data: Readonly<Record<string, Readonly<Record<string, string>>>>;
  readonly timestamp?: string;
}

export function multiLanguageCacheKey(urn: string): string {
  return `v${MULTI_LANGUAGE_CACHE_VERSION}:${urn}`;
}

export function parseMultiLanguageDocument(raw: unknown): SpecMultiLanguage | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const rawData = obj["data"];
  if (!rawData || typeof rawData !== "object" || Array.isArray(rawData)) return null;
  const data: Record<string, Record<string, string>> = {};
  for (const [lang, table] of Object.entries(rawData as Record<string, unknown>)) {
    if (!table || typeof table !== "object" || Array.isArray(table)) continue;
    const entries: Record<string, string> = {};
    for (const [key, value] of Object.entries(table as Record<string, unknown>)) {
      if (typeof value === "string" && value !== "") entries[key] = value;
    }
    if (Object.keys(entries).length > 0) data[lang] = entries;
  }
  return {
    data,
    ...(typeof obj["timestamp"] === "string" ? { timestamp: obj["timestamp"] } : {}),
  };
}

/** Chinese UI prefers its own table, then the other Chinese table, then English. */
export function multiLanguageKeys(language: AppLanguage): readonly string[] {
  if (language === "zh-Hant") return ["zh_tw", "zh_cn", "en"];
  if (language === "zh-Hans") return ["zh_cn", "en"];
  return ["en"];
}

function padded(value: number): string {
  return String(Math.max(0, value)).padStart(3, "0");
}

export function serviceKey(siid: number): string {
  return `service:${padded(siid)}`;
}

export function propertyKey(siid: number, piid: number): string {
  return `${serviceKey(siid)}:property:${padded(piid)}`;
}

export function valueListKey(siid: number, piid: number, index: number): string {
  return `${propertyKey(siid, piid)}:valuelist:${padded(index)}`;
}

/** Pure: the cached spec is never mutated, so a UI language change takes effect on next resolve. */
export function applyMultiLanguage(
  spec: MiotDeviceSpec,
  translations: SpecMultiLanguage | null | undefined,
  language: AppLanguage,
): MiotDeviceSpec {
  if (!translations || Object.keys(translations.data).length === 0) return spec;
  const chain = multiLanguageKeys(language);

  function label(key: string): string | undefined {
    for (const lang of chain) {
      const value = translations!.data[lang]?.[key];
      if (value) return value;
    }
    return undefined;
  }

  return {
    ...spec,
    services: spec.services.map((service) => {
      const serviceDescription = label(serviceKey(service.iid));
      return {
        ...service,
        ...(serviceDescription ? { description: serviceDescription } : {}),
        properties: service.properties.map((property) => {
          const description = label(propertyKey(service.iid, property.iid));
          const valueList = property.valueList
            ? property.valueList.map((item, index): MiotValueListItem => {
                const translated = label(valueListKey(service.iid, property.iid, index));
                return translated ? { ...item, description: translated } : { ...item };
              })
            : property.valueList;
          return {
            ...property,
            ...(description ? { description } : {}),
            ...(valueList ? { valueList } : {}),
          };
        }),
      };
    }),
  };
}
