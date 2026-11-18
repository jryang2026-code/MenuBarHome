import type { AssistantSuggestion } from "../core/models.js";
import type { QRLoginTicket } from "../core/miCloudClient.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoAction } from "./appTypes.js";
import { cancelRunningBatch } from "./intentExecution.js";
import type { SourceEpoch } from "./sourceEpoch.js";
import { abortVoiceInput, clearUndoHoverPause } from "./speechGuard.js";

/**
 * Structural slice of `MenuMijiaWindowsApp` that a connection-source switch
 * operates on. Production always passes the real app; the narrow type lets
 * `SettingsEventsHost` and friends stay declarative host interfaces.
 */
export interface SourceSwitchHost {
  readonly sourceEpoch: SourceEpoch;
  /** Transient pipeline state that every source switch clears. */
  readonly pipeline: { clearTransientState(): void };
  timerSnapshot: { identity: string; sourceRevision: number } | null;
  isSyncingCloud: boolean;
  isPollingQR: boolean;
  qrTicket: QRLoginTicket | null;
  isResolvingIntent: boolean;
  aiProactiveSuggestions: AssistantSuggestion[] | null;
  aiProactiveSignature: string | null;
  isRefreshingProactive: boolean;
  proactiveRetryAfterMs: number | null;
  haConnectionError: string | null;
  lastUndoAction: UndoAction | null;
  pendingCloudConsent: { utterance: string; endpoint: string } | null;
  lastManuallyUsedLightId: string | null;
  pendingSuggestions: AssistantSuggestion[];
  applyPanelHeight(): void;
  clearPendingHighRisk(options?: { readonly syncPin?: boolean }): void;
}

/** Structural slice the home switch operates on; see `switchHome`. */
export interface SwitchHomeHost {
  readonly sourceEpoch: SourceEpoch;
  isSyncingCloud: boolean;
  aiProactiveSuggestions: AssistantSuggestion[] | null;
  aiProactiveSignature: string | null;
  isRefreshingProactive: boolean;
  proactiveRetryAfterMs: number | null;
}

/**
 * Switches the connection source: aborts source-bound work, clears every
 * pending confirmation, and advances the source epoch (which also invalidates
 * the home and local-write levels). `reason` names the call site
 * (`"qr-login-success"`, `"settings-connection-mode"`, …) for future
 * diagnostics; the switch itself treats every reason identically. The only
 * entry that advances the `"source"` level is this function; `switchHome`
 * advances the `"home"` level.
 */
export function switchSource(host: SourceSwitchHost, reason: string): void {
  host.pipeline.clearTransientState();
  // The speech-guard helpers are declared against the concrete app; every production host is
  // the real MenuMijiaWindowsApp, and SourceSwitchHost is its structural slice.
  const app = host as MenuMijiaWindowsApp;
  abortVoiceInput(app);
  // Advance the epoch before resolving any pending URL confirmation so the drain loop sees
  // queued links as belonging to the previous source and cancels them cleanly.
  host.sourceEpoch.advance("source");
  cancelRunningBatch(host, "sourceChanged");
  clearUndoHoverPause(app);
  host.timerSnapshot = null;
  host.isSyncingCloud = false;
  host.isPollingQR = false;
  host.qrTicket = null;
  host.isResolvingIntent = false;
  host.aiProactiveSuggestions = null;
  host.aiProactiveSignature = null;
  host.isRefreshingProactive = false;
  host.proactiveRetryAfterMs = null;
  host.applyPanelHeight();
  host.haConnectionError = null;
  host.lastUndoAction = null;
  host.pendingCloudConsent = null;
  host.clearPendingHighRisk();
  host.lastManuallyUsedLightId = null;
  host.pendingSuggestions = [];
}

/**
 * The invalidation half of `selectHome`: advances the home epoch (home ⊃
 * localWrite) and drops the stale work a home switch must drop. Selection,
 * saving and re-rendering stay in `selectHome` (ui/app.ts).
 */
export function switchHome(host: SwitchHomeHost): void {
  // Invalidate any in-flight cloud refresh from the previous home so it cannot overwrite the new selection.
  host.sourceEpoch.advance("home");
  host.isSyncingCloud = false;
  // A different home is a different suggestion context even at the same ambient signature (Codex #116 review).
  host.aiProactiveSuggestions = null;
  host.aiProactiveSignature = null;
  host.isRefreshingProactive = false;
  host.proactiveRetryAfterMs = null;
}
