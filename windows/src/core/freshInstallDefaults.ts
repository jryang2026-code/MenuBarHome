/**
 * Fresh-install feature switches (P5b-W).
 *
 * `Shared/capability-manifest.json` owns `defaultOnFreshInstall`; this module applies it to the
 * Windows settings for a brand-new install only. The install identity — mode, enabled features and
 * the manifest's hard-dependency cascade — always comes from P4a-W's
 * `resolveCapabilityInstallSelection` / `normalizeCapabilitySelection`, and is never re-derived
 * here, so an upgrade keeps the switches it already had and an uncertain identity read changes
 * nothing (fail-closed).
 *
 * A missing switch (`undefined`) means "the user never chose": only that state is filled in, so an
 * explicit choice, including turning a fresh-install default back on, survives every later start.
 * The resolved values are not written back on their own — a write would feed a settings file into
 * P4a-W's install identity and consume the fresh-install evidence this feature depends on.
 */

import type { FeatureID } from "./capabilityManifest.js";
import type { CapabilitySelection, CapabilityInstallResolution } from "./capabilityReferenceVerdict.js";

/** Settings fields that carry a feature switch whose default comes from the shared manifest. */
export interface FeatureSwitchSettings {
  aiAssistantEnabled?: boolean;
  proactiveSuggestionsEnabled?: boolean;
}

export type FeatureSwitchKey = keyof FeatureSwitchSettings;

export const FEATURE_SWITCH_CAPABILITIES = {
  aiAssistantEnabled: "ai-assistant",
  proactiveSuggestionsEnabled: "proactive-suggestions",
} as const satisfies Record<FeatureSwitchKey, FeatureID>;

export interface FreshInstallDefaultsOutcome {
  /** True when at least one switch was still unset and got its manifest default. */
  readonly applied: boolean;
  readonly changedSwitches: readonly FeatureSwitchKey[];
}

/** The P4a-W resolution an install already produced; only `mode` and `enabledFeatures` matter. */
export type FreshInstallEvidence = Pick<CapabilityInstallResolution, "mode"> & {
  readonly selection: Pick<CapabilitySelection, "enabledFeatures">;
};

/**
 * Fills the still-unset feature switches from the resolved fresh-install selection. Every other
 * mode (an explicit selection, a silently migrated legacy user, a retryable uncertain read) leaves
 * the settings untouched.
 */
export function applyFreshInstallFeatureSwitches(
  settings: FeatureSwitchSettings,
  install: FreshInstallEvidence,
): FreshInstallDefaultsOutcome {
  if (install.mode !== "freshInstall") return { applied: false, changedSwitches: [] };
  const changedSwitches: FeatureSwitchKey[] = [];
  for (const key of Object.keys(FEATURE_SWITCH_CAPABILITIES) as FeatureSwitchKey[]) {
    if (settings[key] !== undefined) continue;
    // `resolveCapabilityInstallSelection` already dropped capabilities whose hard dependencies the
    // fresh install does not turn on, so the normalized selection is the answer.
    settings[key] = install.selection.enabledFeatures.includes(FEATURE_SWITCH_CAPABILITIES[key]);
    changedSwitches.push(key);
  }
  return { applied: changedSwitches.length > 0, changedSwitches };
}
