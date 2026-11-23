import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { DEVICE_LABELS } from "../src/core/deviceLabels.js";
import { setLanguage } from "../src/core/i18n.js";
import { facetTitle, genericSymbolName, genericTypeTitle } from "../src/core/miotFacetText.js";
import type { AppLanguage } from "../src/core/i18n.js";
import type { FacetControl } from "../src/core/models.js";

/**
 * #11: facet and device-type labels moved into `Shared/deviceLabels.json`. The golden file was
 * exported from the old tables before they were deleted, so this suite proves the migration changed
 * no title and no glyph in any language. macOS reads the `macos` section of the same fixture: the
 * two ends localize some labels differently and this refactor keeps each end exactly as it was.
 */
interface Titles {
  readonly "zh-Hans": string;
  readonly "zh-Hant": string;
  readonly en: string;
}
interface PlatformLabels {
  readonly facetTitles: Readonly<Record<string, Titles>>;
  readonly deviceTypes: Readonly<Record<string, Titles | null>>;
}
interface Golden {
  readonly version: number;
  readonly defaultSymbol: string;
  readonly symbols: Readonly<Record<string, string>>;
  readonly windows: PlatformLabels;
}

const golden = JSON.parse(
  readFileSync(resolve(import.meta.dirname, "../../Tests/Fixtures/device_labels_golden.json"), "utf8"),
) as Golden;

const languages: readonly AppLanguage[] = ["zh-Hans", "zh-Hant", "en"];

function inLanguage(language: AppLanguage, body: () => string): string {
  setLanguage(language);
  try {
    return body();
  } finally {
    setLanguage("zh-Hans");
  }
}

function controlNamed(name: string): FacetControl {
  return {
    id: `x.${name}`,
    kind: "reading",
    name,
    title: null,
    serviceName: "x",
    unit: null,
    scale: null,
    value: null,
    options: [],
    range: null,
    isWritable: false,
    writesByDefault: false,
    isHighValue: false,
    target: null,
  };
}

function humanizedFacetName(raw: string): string {
  const words = raw.replaceAll("-", " ");
  return words.slice(0, 1).toUpperCase() + words.slice(1);
}

describe("shared device labels", () => {
  it("loads the shared document both platforms ship", () => {
    assert.equal(DEVICE_LABELS.schemaVersion, 1);
    assert.equal(Object.keys(DEVICE_LABELS.facetTitles).length, 41);
    assert.equal(Object.keys(DEVICE_LABELS.familyFacetTitles).length, 42);
    assert.equal(Object.keys(DEVICE_LABELS.deviceTypes).length, 32);
  });

  it("keeps every facet title identical to the pre-migration table in every language", () => {
    assert.equal(golden.version, 1);
    assert.equal(Object.keys(golden.windows.facetTitles).length, 83);
    for (const [name, expected] of Object.entries(golden.windows.facetTitles)) {
      const control = controlNamed(name);
      for (const language of languages) {
        assert.equal(
          inLanguage(language, () => facetTitle(control)),
          expected[language],
          `${name} in ${language}`,
        );
      }
    }
  });

  it("keeps every device-type title and symbol identical to the pre-migration table", () => {
    assert.equal(Object.keys(golden.windows.deviceTypes).length, 32);
    for (const [deviceType, expected] of Object.entries(golden.windows.deviceTypes)) {
      for (const language of languages) {
        const want = expected ? expected[language] : humanizedFacetName(deviceType);
        assert.equal(inLanguage(language, () => genericTypeTitle(deviceType)), want, `${deviceType} in ${language}`);
      }
      assert.equal(genericSymbolName(deviceType), golden.symbols[deviceType], `${deviceType} symbol`);
    }
    assert.equal(genericSymbolName("unknown-device-type"), golden.defaultSymbol);
  });

  it("still prefers the spec description, then the humanized name, for an unlisted facet", () => {
    assert.equal(facetTitle({ ...controlNamed("vendor-only"), title: " Vendor Name " }), "Vendor Name");
    assert.equal(facetTitle(controlNamed("vendor-only")), "Vendor only");
  });
});
