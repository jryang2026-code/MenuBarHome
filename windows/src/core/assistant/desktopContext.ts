/** Controlled boolean-only desktop signals for AI prompts & proactive ranking (ADR-0015). */
export type DesktopAmbientSignal = "inMeeting" | "externalDisplayConnected" | "focusActive" | "lateNightWork" | "mediaPlaying";
export interface DesktopAmbientContext {
  readonly inMeeting: boolean; readonly externalDisplayConnected: boolean; readonly focusActive: boolean;
  readonly lateNightWork: boolean; readonly mediaPlaying: boolean;
}
export const EMPTY_DESKTOP_AMBIENT_CONTEXT: DesktopAmbientContext = Object.freeze({
  inMeeting: false, externalDisplayConnected: false, focusActive: false, lateNightWork: false, mediaPlaying: false,
});
const TAGS: Readonly<Record<DesktopAmbientSignal, string>> = {
  inMeeting: "会议中", externalDisplayConnected: "外接显示器", focusActive: "专注模式", lateNightWork: "深夜办公", mediaPlaying: "媒体播放中",
};
const SIGNAL_KEYS: readonly DesktopAmbientSignal[] = ["inMeeting", "externalDisplayConnected", "focusActive", "lateNightWork", "mediaPlaying"];

export function normalizeDesktopAmbientContext(input?: Partial<DesktopAmbientContext> | null): DesktopAmbientContext {
  if (!input) return EMPTY_DESKTOP_AMBIENT_CONTEXT;
  return {
    inMeeting: input.inMeeting === true, externalDisplayConnected: input.externalDisplayConnected === true,
    focusActive: input.focusActive === true, lateNightWork: input.lateNightWork === true, mediaPlaying: input.mediaPlaying === true,
  };
}
export function desktopAmbientSignals(context?: Partial<DesktopAmbientContext> | null): DesktopAmbientSignal[] {
  const c = normalizeDesktopAmbientContext(context);
  return SIGNAL_KEYS.filter((k) => c[k]);
}
export const hasActiveDesktopAmbientSignals = (context?: Partial<DesktopAmbientContext> | null): boolean => desktopAmbientSignals(context).length > 0;
export const desktopAmbientSignatureToken = (context?: Partial<DesktopAmbientContext> | null): string => desktopAmbientSignals(context).join(",");
export function formatDesktopAmbientPromptSummary(context?: Partial<DesktopAmbientContext> | null): string {
  const s = desktopAmbientSignals(context);
  return s.length === 0 ? "" : `桌面情境：${s.map((k) => TAGS[k]).join("、")}`;
}
export function mergeDesktopAmbientIntoEnvironment(environment: string, context?: Partial<DesktopAmbientContext> | null): string {
  const tag = formatDesktopAmbientPromptSummary(context);
  if (!tag) return environment;
  const trimmed = environment.trim();
  return !trimmed ? tag : (trimmed.includes(tag) ? trimmed : `${trimmed}；${tag}`);
}
export interface RawDesktopAmbientObservation {
  readonly cameraInUse?: boolean | null; readonly microphoneInUse?: boolean | null; readonly externalDisplayCount?: number | null;
  readonly focusActive?: boolean | null; readonly isUserPresent?: boolean | null; readonly mediaPlaying?: boolean | null;
  readonly now?: Date; readonly [extra: string]: unknown;
}
/** Projects raw OS observations to booleans only, discarding window/calendar titles and Wi-Fi SSIDs. */
export function projectDesktopAmbientContext(raw: RawDesktopAmbientObservation | null | undefined): DesktopAmbientContext {
  if (!raw) return EMPTY_DESKTOP_AMBIENT_CONTEXT;
  const hour = (raw.now ?? new Date()).getHours();
  return {
    inMeeting: raw.cameraInUse === true || raw.microphoneInUse === true,
    externalDisplayConnected: typeof raw.externalDisplayCount === "number" && Number.isFinite(raw.externalDisplayCount) && raw.externalDisplayCount > 0,
    focusActive: raw.focusActive === true, lateNightWork: raw.isUserPresent === true && (hour >= 23 || hour < 6), mediaPlaying: raw.mediaPlaying === true,
  };
}
