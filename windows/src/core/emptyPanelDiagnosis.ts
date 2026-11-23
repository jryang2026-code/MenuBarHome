import { normalizeMiCloudRegion } from "./miCloudClient.js";

/** Session state of the Xiaomi Cloud account used by `diagnoseEmptyPanel`. */
export type MiAccountSessionState = "missing" | "active" | "expired";

/** Outcome of the most recent Xiaomi Cloud sync attempt. */
export type EmptyPanelSyncOutcome = "pending" | "succeeded" | "authFailed" | "failed";

/** Actionable reason why a signed-in Xiaomi Cloud panel shows 0 devices (#67, #76). */
export type EmptyPanelReason =
  | "sessionReauthRequired"
  | "syncFailed"
  | "possibleWrongRegion"
  | "noHomes"
  | "homesWithoutDevices";

/** Primary recovery button shown in the empty panel. Reuses existing entry points only. */
export type EmptyPanelSuggestedAction =
  | "reauth"
  | "switchRegion"
  | "confirmMiHome"
  | "copyDiagnostics";

export interface EmptyPanelDiagnosisInput {
  readonly isDemoMode: boolean;
  readonly sessionState: MiAccountSessionState;
  readonly homeCount: number;
  readonly deviceCount: number;
  readonly lastSyncOutcome: EmptyPanelSyncOutcome;
  readonly region: string;
  readonly hasOtherHomesWithDevices?: boolean;
}

export function suggestedActionForEmptyPanelReason(reason: EmptyPanelReason): EmptyPanelSuggestedAction {
  switch (reason) {
    case "sessionReauthRequired":
      return "reauth";
    case "possibleWrongRegion":
      return "switchRegion";
    case "noHomes":
      return "confirmMiHome";
    case "homesWithoutDevices":
    case "syncFailed":
      return "copyDiagnostics";
  }
}

/**
 * Pure, cross-platform diagnosis for the "signed in to Xiaomi Cloud, 0 devices" empty panel (#67, #76).
 *
 * Mirrors `Sources/MijiaCore/EmptyPanelDiagnosis.swift` and is locked to
 * `Tests/Fixtures/empty_panel_diagnosis_golden.json`.
 */
export function diagnoseEmptyPanel(input: EmptyPanelDiagnosisInput): EmptyPanelReason | null {
  if (input.isDemoMode) return null;
  if (input.deviceCount > 0) return null;
  if (input.hasOtherHomesWithDevices === true) return null;
  if (input.sessionState === "missing") return null;

  if (input.sessionState === "expired" || input.lastSyncOutcome === "authFailed") {
    return "sessionReauthRequired";
  }
  if (input.lastSyncOutcome === "pending") {
    return null;
  }
  if (input.lastSyncOutcome === "failed") {
    return "syncFailed";
  }

  if (input.homeCount <= 0) {
    const region = normalizeMiCloudRegion(input.region);
    return region === "cn" ? "noHomes" : "possibleWrongRegion";
  }
  return "homesWithoutDevices";
}
