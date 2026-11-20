/**
 * AI feature lifecycle state (P5a-W): the enable switch and per-provider removal.
 *
 * The enable switch only gates requests — local parsing, learned shortcuts, scheduled
 * commands and the write gates keep working, and the saved provider config plus key
 * slots stay on disk so re-enabling restores the previous setup.
 */

import { ASSISTANT_PROVIDER_PRESETS, assistantEndpointIdentity, inferAssistantPreset } from "./provider.js";

/** Missing field means enabled: every pre-existing user keeps the old always-on behavior. */
export function isAiAssistantEnabled(settings: { readonly aiAssistantEnabled?: boolean }): boolean {
  return settings.aiAssistantEnabled !== false;
}

/**
 * 主动建议 (`proactive-suggestions`) on its own switch (P5b-W).
 *
 * Missing field means enabled, because `Shared/capability-manifest.json` marks the capability
 * `defaultOnFreshInstall: true`; upgrades keep the suggestions they had before the switch existed.
 * When off, the shared tick never reaches the suggestion branch, `currentProactiveSuggestions`
 * returns nothing without computing a signature or ranking habits, and no prompt or count is
 * produced — safety alerts, undo and scheduled commands keep their own cadence.
 */
export function isProactiveSuggestionsEnabled(settings: { readonly proactiveSuggestionsEnabled?: boolean }): boolean {
  return settings.proactiveSuggestionsEnabled !== false;
}

/** Settings fields that describe the active provider; mirrors `PersistedSettings`. */
export interface AssistantRemovalSettings {
  assistantBaseURL: string;
  assistantModel: string;
  openRouterApiKey: string;
  assistantKeyEndpoint: string | null;
  assistantCustomKeyEndpoint: string | null;
  assistantLegacyKeyEndpoint: string | null;
  cloudConsentEndpoints: string[];
}

export interface AssistantProviderRemovalOutcome {
  /** True when the removed preset is the one configured in the saved settings. */
  readonly activeProviderRemoved: boolean;
  /** Endpoint identities whose cloud-send consent was pruned (removed provider only). */
  readonly prunedConsentEndpoints: readonly string[];
  /** Endpoint bindings cleared because they belonged to the removed provider. */
  readonly clearedBindings: readonly string[];
  /** Provider config after the removal, for the settings form fields. */
  readonly nextBaseURL: string;
  readonly nextModel: string;
}

/** The endpoint host(+port) string a key/consent binding stores; null when unparseable. */
function bindingOwnerPresetId(binding: string | null): string | null {
  const identity = binding?.trim() ?? "";
  if (identity === "") return null;
  return inferAssistantPreset(`https://${identity}`).id;
}

/**
 * Removes one provider's local config and key bindings, leaving every other provider's
 * key slot, endpoint binding and cloud consent untouched (P5a-W acceptance #2).
 *
 * Mutates `settings` and `keysByPreset` in place; the caller persists the credential
 * vault afterwards so the removed preset's key slot is deleted from the OS store while
 * sibling slots survive.
 */
export function removeAssistantProviderState(args: {
  presetId: string;
  settings: AssistantRemovalSettings;
  keysByPreset: Record<string, string>;
}): AssistantProviderRemovalOutcome {
  const { presetId, settings, keysByPreset } = args;
  const activePresetId = inferAssistantPreset(settings.assistantBaseURL || ASSISTANT_PROVIDER_PRESETS[0]!.defaultBaseURL).id;
  const activeProviderRemoved = presetId === activePresetId;

  // The key slot of the removed provider goes; sibling slots are not touched here.
  delete keysByPreset[presetId];

  const clearedBindings: string[] = [];
  for (const binding of ["assistantKeyEndpoint", "assistantCustomKeyEndpoint", "assistantLegacyKeyEndpoint"] as const) {
    if (bindingOwnerPresetId(settings[binding]) === presetId) {
      settings[binding] = null;
      clearedBindings.push(binding);
    }
  }

  // Consent entries are endpoint identities; prune exactly those owned by the removed
  // provider — including ones left over from a provider that is no longer active.
  const prunedConsentEndpoints = settings.cloudConsentEndpoints.filter(
    (endpoint) => bindingOwnerPresetId(endpoint) === presetId,
  );
  settings.cloudConsentEndpoints = settings.cloudConsentEndpoints.filter(
    (endpoint) => !prunedConsentEndpoints.includes(endpoint),
  );

  let nextBaseURL = settings.assistantBaseURL;
  let nextModel = settings.assistantModel;
  if (activeProviderRemoved) {
    // The active provider is gone: fall back to the app default preset.
    const fallback = ASSISTANT_PROVIDER_PRESETS[0]!;
    nextBaseURL = fallback.defaultBaseURL;
    nextModel = fallback.defaultModel;
    settings.assistantBaseURL = nextBaseURL;
    settings.assistantModel = nextModel;
    // The default preset's saved key (if any) becomes the active key again. Leaving the
    // field empty would make `credentialsFromSettings` read it as "active preset has no
    // key" and delete that unrelated slot on the next vault persist.
    settings.openRouterApiKey = keysByPreset[fallback.id]?.trim() ?? "";
    settings.assistantKeyEndpoint =
      settings.openRouterApiKey !== "" ? assistantEndpointIdentity(nextBaseURL) : null;
  }

  return { activeProviderRemoved, prunedConsentEndpoints, clearedBindings, nextBaseURL, nextModel };
}
