import type { DeviceCommand } from "../models.js";
import {
  makeMiotActionAddress,
  miotShortName,
  parseMiotActionAddress,
  type MiotAction,
  type MiotDeviceSpec,
  type MiotProperty,
  type MiotService,
} from "./spec.js";

export const SPEAKER_TEXT_MAX_LENGTH = 500;

export type SpeakerTextMode = "tts" | "directive";

export interface ResolvedSpeakerActionIds {
  readonly ttsActionId: string | null;
  readonly directiveActionId: string | null;
}

export function normalizeSpeakerText(
  raw: unknown,
  maxLength = SPEAKER_TEXT_MAX_LENGTH,
): string {
  if (typeof raw !== "string") {
    throw new Error("Speaker text must be a string");
  }
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    throw new Error("Speaker text cannot be empty");
  }
  const codePointLength = Array.from(trimmed).length;
  if (codePointLength > maxLength) {
    throw new Error(`Speaker text exceeds maximum length (${maxLength})`);
  }
  return trimmed;
}

function isTextContentProperty(prop: MiotProperty | undefined, requireExactShortName: boolean): boolean {
  if (!prop || prop.format !== "string") return false;
  return requireExactShortName ? miotShortName(prop.type) === "text-content" : true;
}

function isSilentExecutionProperty(prop: MiotProperty | undefined): boolean {
  if (!prop) return false;
  if (miotShortName(prop.type) === "silent-execution") return true;
  return prop.format === "bool" || prop.format.startsWith("uint") || prop.format.startsWith("int");
}

function findTtsAction(
  did: string,
  services: readonly MiotService[],
): string | null {
  for (const service of services) {
    for (const action of service.actions) {
      if (miotShortName(action.type) !== "play-text") continue;
      const inputs = action.in ?? [];
      if (inputs.length !== 1) continue;
      const prop = service.properties.find((p) => p.iid === inputs[0]);
      if (isTextContentProperty(prop, true)) {
        return makeMiotActionAddress(did, service.iid, action.iid);
      }
    }
  }
  for (const service of services) {
    for (const action of service.actions) {
      if (miotShortName(action.type) !== "play-text") continue;
      const inputs = action.in ?? [];
      if (inputs.length === 1) {
        const prop = service.properties.find((p) => p.iid === inputs[0]);
        if (isTextContentProperty(prop, false)) {
          return makeMiotActionAddress(did, service.iid, action.iid);
        }
      } else if (inputs.length === 0) {
        return makeMiotActionAddress(did, service.iid, action.iid);
      }
    }
  }
  return null;
}

function findDirectiveAction(
  did: string,
  services: readonly MiotService[],
): string | null {
  for (const service of services) {
    for (const action of service.actions) {
      if (miotShortName(action.type) !== "execute-text-directive") continue;
      const inputs = action.in ?? [];
      if (inputs.length !== 2) continue;
      const textProp = service.properties.find((p) => p.iid === inputs[0]);
      const silentProp = service.properties.find((p) => p.iid === inputs[1]);
      if (
        isTextContentProperty(textProp, true) &&
        silentProp !== undefined &&
        miotShortName(silentProp.type) === "silent-execution"
      ) {
        return makeMiotActionAddress(did, service.iid, action.iid);
      }
    }
  }
  for (const service of services) {
    for (const action of service.actions) {
      if (miotShortName(action.type) !== "execute-text-directive") continue;
      const inputs = action.in ?? [];
      if (inputs.length !== 1) continue;
      const textProp = service.properties.find((p) => p.iid === inputs[0]);
      if (isTextContentProperty(textProp, false)) {
        return makeMiotActionAddress(did, service.iid, action.iid);
      }
    }
  }
  for (const service of services) {
    for (const action of service.actions) {
      if (miotShortName(action.type) !== "execute-text-directive") continue;
      const inputs = action.in ?? [];
      if (inputs.length === 0) {
        return makeMiotActionAddress(did, service.iid, action.iid);
      }
    }
  }
  return null;
}

export function resolveSpeakerActionIds(
  did: string,
  spec: MiotDeviceSpec,
): ResolvedSpeakerActionIds {
  const candidateServices = [
    ...spec.services.filter((s) => miotShortName(s.type) === "intelligent-speaker"),
    ...spec.services.filter((s) => miotShortName(s.type) === "speaker"),
  ];
  if (candidateServices.length === 0) {
    return { ttsActionId: null, directiveActionId: null };
  }
  return {
    ttsActionId: findTtsAction(did, candidateServices),
    directiveActionId: findDirectiveAction(did, candidateServices),
  };
}

export function buildSpeakerTextCommand(
  actionId: string,
  rawText: string,
  options?: { readonly silent?: boolean; readonly maxLength?: number },
): DeviceCommand {
  if (!parseMiotActionAddress(actionId)) {
    throw new Error(`Invalid speaker MIoT action address: ${actionId}`);
  }
  const trimmed = normalizeSpeakerText(rawText, options?.maxLength ?? SPEAKER_TEXT_MAX_LENGTH);
  const args: unknown[] =
    options?.silent !== undefined ? [trimmed, options.silent] : [trimmed];
  return {
    kind: "pressButton",
    entityId: actionId,
    arguments: args,
  };
}

export function isSpeakerTextAction(action: MiotAction): boolean {
  const short = miotShortName(action.type);
  return short === "play-text" || short === "execute-text-directive";
}

function coerceSilentExecutionArg(
  prop: MiotProperty,
  rawSilent: unknown,
  entityId: string,
): boolean | number {
  let desiredSilent: boolean;
  if (typeof rawSilent === "boolean") {
    desiredSilent = rawSilent;
  } else if (typeof rawSilent === "number" && Number.isFinite(rawSilent)) {
    if (prop.valueList && prop.valueList.length > 0) {
      if (!Number.isInteger(rawSilent) || !prop.valueList.some((item) => item.value === rawSilent)) {
        throw new Error(`Unsupported action option: ${rawSilent}`);
      }
      return rawSilent;
    }
    desiredSilent = rawSilent !== 0;
  } else {
    throw new Error(`Unsupported speaker silent-execution input: ${entityId}`);
  }

  if (prop.valueList && prop.valueList.length > 0) {
    const match = prop.valueList.find((item) => {
      const desc = item.description.trim().toLowerCase();
      return desiredSilent
        ? desc.includes("silent") || desc.includes("静默") || desc === "true" || desc === "on" || desc === "yes"
        : desc.includes("speak") || desc.includes("voice") || desc.includes("播报") || desc === "false" || desc === "off" || desc === "no";
    });
    if (match) return match.value;
    const numericTarget = desiredSilent ? 1 : 0;
    const byNum = prop.valueList.find((item) => item.value === numericTarget);
    return (byNum ?? prop.valueList[0]!).value;
  }

  if (prop.format === "bool") {
    return desiredSilent;
  }
  const rawNum = desiredSilent ? 1 : 0;
  if (prop.valueRange && prop.valueRange.length >= 2) {
    const lo = prop.valueRange[0] ?? rawNum;
    const hi = prop.valueRange[1] ?? rawNum;
    return Math.round(Math.min(hi, Math.max(lo, rawNum)));
  }
  return rawNum;
}

export function mapSpeakerActionInputs(
  service: MiotService,
  action: MiotAction,
  supplied: readonly unknown[],
  entityId: string,
): unknown[] {
  if (supplied.length === 0) {
    throw new Error(`Action needs inputs: ${entityId}`);
  }
  const short = miotShortName(action.type);
  const trimmed = normalizeSpeakerText(supplied[0]);
  const declaredInputs = action.in ?? [];

  if (short === "play-text") {
    if (supplied.length > 1) {
      throw new Error(`Unsupported action inputs: ${entityId}`);
    }
    if (declaredInputs.length === 0) {
      return [trimmed];
    }
    if (declaredInputs.length === 1) {
      const textProp = service.properties.find((p) => p.iid === declaredInputs[0]);
      if (!isTextContentProperty(textProp, false)) {
        throw new Error(`Unsupported speaker action inputs: ${entityId}`);
      }
      return [trimmed];
    }
    throw new Error(`Unsupported speaker action inputs: ${entityId}`);
  }

  if (supplied.length > 2) {
    throw new Error(`Unsupported action inputs: ${entityId}`);
  }
  if (declaredInputs.length === 0) {
    return [trimmed];
  }
  if (declaredInputs.length === 1) {
    const textProp = service.properties.find((p) => p.iid === declaredInputs[0]);
    if (!isTextContentProperty(textProp, false)) {
      throw new Error(`Unsupported speaker action inputs: ${entityId}`);
    }
    return [trimmed];
  }
  if (declaredInputs.length === 2) {
    const textProp = service.properties.find((p) => p.iid === declaredInputs[0]);
    const silentProp = service.properties.find((p) => p.iid === declaredInputs[1]);
    if (!isTextContentProperty(textProp, false) || !isSilentExecutionProperty(silentProp)) {
      throw new Error(`Unsupported speaker action inputs: ${entityId}`);
    }
    const rawSilent = supplied.length >= 2 ? supplied[1] : true;
    return [trimmed, coerceSilentExecutionArg(silentProp!, rawSilent, entityId)];
  }
  throw new Error(`Unsupported speaker action inputs: ${entityId}`);
}
