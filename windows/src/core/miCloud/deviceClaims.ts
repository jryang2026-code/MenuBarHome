/**
 * Which MIoT service may claim a card, in which order, and under which conditions (#26), read from
 * `Shared/deviceClaims.json`. macOS ships a byte-identical copy in `Sources/MijiaCore/Resources/`
 * and decodes it through `DeviceClaims.swift`, so the two claim ladders are one document — Windows
 * used to carry a second priority array with `television`/`stb` and a `stb` service alias macOS did
 * not have.
 *
 * The document only carries choices: the ladder order, the device-type aliases, two closed claim
 * conditions, the appliance service list and the light-like fallback tokens. What a claimed service
 * renders as stays in this end's builder switch, and a rung whose card family the switch does not
 * draw is marked `renderers` so the gap is explicit instead of silent
 * (`scripts/check_device_rules.py` pins it to a budget).
 */
import sharedClaimsJson from "../../../../Shared/deviceClaims.json";
import { miotShortName, type MiotDeviceSpec } from "./spec.js";

/** A closed claim condition. Adding a kind needs a code change on both ends (closed-data rule). */
export interface ClaimCondition {
  /** The spec must publish `property` on `service`; a mains breaker meters electric power (#265). */
  readonly serviceHasProperty?: { readonly service: string; readonly property: string };
  /** Only a device whose own type is this service may claim it (#300). */
  readonly deviceTypeIsService?: boolean;
}

export interface ClaimLadderEntry {
  readonly service: string;
  readonly claimableWhen?: ClaimCondition;
  /** Platforms whose builder list renders this claim; absent means both. */
  readonly renderers?: readonly string[];
}

export interface FallbackTypeTokens {
  readonly service: string;
  readonly tokens: readonly string[];
}

export interface DeviceClaimsDocument {
  readonly schemaVersion: number;
  readonly preferredServices: Readonly<Record<string, readonly string[]>>;
  readonly ladder: readonly ClaimLadderEntry[];
  readonly applianceServices: readonly string[];
  readonly fallbackTypeTokens: readonly FallbackTypeTokens[];
}

/** The one shared document, imported at build time. Same file the macOS bundle ships. */
export const DEVICE_CLAIMS: DeviceClaimsDocument = sharedClaimsJson;

/** The claim ladder in document order: the first rung the spec publishes wins. */
export const CLAIM_LADDER: readonly string[] = DEVICE_CLAIMS.ladder.map((entry) => entry.service);

/**
 * Services that count as this device type's own primary service, or its own name when the document
 * does not alias it. Appliance profiles are checked by the caller first, as before (#4).
 */
export function preferredClaimServices(deviceType: string): readonly string[] {
  return DEVICE_CLAIMS.preferredServices[deviceType] ?? [deviceType];
}

/**
 * Whether `service` may claim `spec`: the document's two closed conditions, nothing else. A service
 * the document does not list is a code-side rung with no condition, so a caller never silently
 * loses a card.
 */
export function claimAllows(service: string, spec: MiotDeviceSpec): boolean {
  const rule = DEVICE_CLAIMS.ladder.find((entry) => entry.service === service)?.claimableWhen;
  if (!rule) return true;
  const propertyRule = rule.serviceHasProperty;
  if (propertyRule) {
    const published = spec.services.some(
      (s) =>
        miotShortName(s.type) === propertyRule.service &&
        s.properties.some((p) => miotShortName(p.type) === propertyRule.property),
    );
    if (!published) return false;
  }
  if (rule.deviceTypeIsService === true && miotShortName(spec.type) !== service) return false;
  return true;
}

/** The device-type tokens that let `service` claim a type whose own name contains one. */
export function claimFallbackTokens(service: string): readonly string[] {
  return DEVICE_CLAIMS.fallbackTypeTokens.find((entry) => entry.service === service)?.tokens ?? [];
}
