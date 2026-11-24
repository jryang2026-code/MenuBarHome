/**
 * Per-model declarative MIoT spec patches read from `Shared/specPatches.json`.
 * macOS ships a byte-identical copy in `Sources/MijiaCore/Resources/specPatches.json`
 * and applies the exact same rules in `MiotSpecPatches.swift`.
 */
import sharedSpecPatchesJson from "../../../../Shared/specPatches.json";
import type { MiotDeviceSpec, MiotProperty, MiotValueListItem } from "./spec.js";

export interface SpecPatchPropertyRef {
  readonly siid: number;
  readonly piid: number;
}

export interface SpecPatchPropertyOverride {
  readonly siid: number;
  readonly piid: number;
  readonly access?: readonly string[];
  readonly unit?: string;
  readonly valueRange?: readonly number[];
  readonly valueList?: readonly MiotValueListItem[];
  readonly description?: string;
  readonly note?: string;
}

export interface SpecModelPatch {
  readonly hideProperties?: readonly SpecPatchPropertyRef[];
  readonly properties?: readonly SpecPatchPropertyOverride[];
  readonly note?: string;
}

export interface SpecPatchesDocument {
  readonly schemaVersion: number;
  readonly models: Readonly<Record<string, SpecModelPatch>>;
}

export const SPEC_PATCHES: SpecPatchesDocument = sharedSpecPatchesJson as SpecPatchesDocument;

function propKey(siid: number, piid: number): string {
  return `${siid}.${piid}`;
}

/**
 * Apply any model-specific patch from `document` to `spec`. Pure and idempotent.
 */
export function applySpecPatches(
  spec: MiotDeviceSpec,
  model: string,
  document: SpecPatchesDocument = SPEC_PATCHES,
): MiotDeviceSpec {
  const patch = document.models[model];
  if (!patch) return spec;

  const hidden = new Set<string>();
  for (const ref of patch.hideProperties ?? []) {
    hidden.add(propKey(ref.siid, ref.piid));
  }
  const overrides = new Map<string, SpecPatchPropertyOverride>();
  for (const item of patch.properties ?? []) {
    overrides.set(propKey(item.siid, item.piid), item);
  }
  if (hidden.size === 0 && overrides.size === 0) return spec;

  return {
    ...spec,
    services: spec.services.map((service) => ({
      ...service,
      properties: service.properties.reduce<MiotProperty[]>((acc, prop) => {
        const key = propKey(service.iid, prop.iid);
        if (hidden.has(key)) return acc;
        const override = overrides.get(key);
        if (!override) {
          acc.push(prop);
          return acc;
        }
        acc.push({
          ...prop,
          ...(override.access !== undefined ? { access: [...override.access] } : {}),
          ...(override.unit !== undefined ? { unit: override.unit } : {}),
          ...(override.valueRange !== undefined ? { valueRange: [...override.valueRange] } : {}),
          ...(override.valueList !== undefined
            ? { valueList: override.valueList.map((item) => ({ value: item.value, description: item.description })) }
            : {}),
          ...(override.description !== undefined ? { description: override.description } : {}),
        });
        return acc;
      }, []),
    })),
  };
}
