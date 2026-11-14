import { GrokBall } from "../vendor/grok-ball/grok-ball.js";
import type { GrokBallEngine } from "../vendor/grok-ball/grok-ball.js";

export const GROK_BALL_OFFSET_STORAGE_KEY = "menubarmijia.grokBallOffsetY";
export const GROK_BALL_BASE_MARGIN_TOP_PX = 44;
export const GROK_BALL_MIN_OFFSET_Y_PX = -38;
export const GROK_BALL_DEFAULT_MAX_OFFSET_Y_PX = 480;
export const GROK_BALL_DRAG_THRESHOLD_PX = 6;
export const GROK_BALL_VOICE_HOLD_MS = 500;

export function clampGrokBallOffsetY(offsetY: number, container?: HTMLElement | null): number {
  if (!Number.isFinite(offsetY)) return 0;
  const popover = container?.querySelector<HTMLElement>(":scope > .cc-popover") ?? container ?? null;
  const measuredHeight = Math.max(
    popover?.clientHeight ?? 0,
    Math.round(popover?.getBoundingClientRect().height ?? 0),
  );
  const maxOffset =
    measuredHeight > 160
      ? Math.max(0, measuredHeight - GROK_BALL_BASE_MARGIN_TOP_PX - 84)
      : GROK_BALL_DEFAULT_MAX_OFFSET_Y_PX;
  return Math.round(Math.min(maxOffset, Math.max(GROK_BALL_MIN_OFFSET_Y_PX, offsetY)));
}

export function loadGrokBallOffsetY(container?: HTMLElement | null): number {
  try {
    const raw = globalThis.localStorage?.getItem(GROK_BALL_OFFSET_STORAGE_KEY);
    if (raw === null || raw === undefined || raw.trim() === "") return 0;
    const parsed = Number(raw);
    if (!Number.isFinite(parsed)) return 0;
    return clampGrokBallOffsetY(parsed, container);
  } catch {
    return 0;
  }
}

export function saveGrokBallOffsetY(offsetY: number): void {
  try {
    const normalized = Math.round(Number.isFinite(offsetY) ? offsetY : 0);
    if (normalized === 0) {
      globalThis.localStorage?.removeItem(GROK_BALL_OFFSET_STORAGE_KEY);
    } else {
      globalThis.localStorage?.setItem(GROK_BALL_OFFSET_STORAGE_KEY, String(normalized));
    }
  } catch {
    return;
  }
}

export class GrokBallView {
  readonly element = document.createElement("span");
  public offsetY = 0;
  public voiceHoldMs = GROK_BALL_VOICE_HOLD_MS;
  private engine: GrokBallEngine | null = null;
  private readonly motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  private previousRect: DOMRect | null = null;
  private relocation: Animation | null = null;

  constructor() {
    this.element.className = "cc-grok-ball";
    this.offsetY = loadGrokBallOffsetY();
    this.motion.addEventListener("change", () => this.updateMotion());
    document.addEventListener("visibilitychange", () => this.updateMotion());
    window.addEventListener("pagehide", () => this.engine?.destroy(), { once: true });
  }

  setOffsetY(offsetY: number, root?: HTMLElement | null, persist = false): number {
    const clamped = clampGrokBallOffsetY(offsetY, root);
    this.offsetY = clamped;
    const sidebar = root?.querySelector<HTMLElement>(":scope > .cc-grok-sidebar");
    if (sidebar) {
      sidebar.dataset.grokOffsetY = String(clamped);
      sidebar.style.marginTop = `${GROK_BALL_BASE_MARGIN_TOP_PX + clamped}px`;
    }
    if (persist) {
      saveGrokBallOffsetY(clamped);
    }
    return clamped;
  }

  prepareMove(): void {
    this.previousRect = this.element.isConnected ? this.element.getBoundingClientRect() : null;
  }

  mount(slot: HTMLElement, emotion: string): void {
    slot.appendChild(this.element);
    if (!this.engine) {
      this.engine = GrokBall.create(this.element, {
        emotion, autostart: !this.motion.matches && !document.hidden, lite: false,
      });
    }
    this.setEmotion(emotion);
    this.updateMotion();
    const previous = this.previousRect;
    const next = this.element.getBoundingClientRect();
    const dragging = slot.closest(".cc-grok-sidebar")?.hasAttribute("data-dragging") === true;
    if (!dragging && !this.motion.matches && previous && previous.width > 0 && next.width > 0 &&
        (Math.abs(previous.x - next.x) > 1 || Math.abs(previous.y - next.y) > 1)) {
      this.relocation?.cancel();
      this.relocation = this.element.animate([
        { transformOrigin: "top left", transform: `translate(${previous.x - next.x}px, ${previous.y - next.y}px) scale(${previous.width / next.width})` },
        { transformOrigin: "top left", transform: "none" },
      ], { duration: 250, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
    }
    this.previousRect = null;
  }

  setEmotion(emotion: string): void {
    this.element.dataset.emotion = emotion;
    if (this.engine?.emotionId !== emotion) this.engine?.setEmotion(emotion);
  }

  setGaze(x: number, y: number): void {
    if (!this.motion.matches) this.engine?.setGaze(x, y);
  }

  private updateMotion(): void {
    const active = !this.motion.matches && !document.hidden;
    this.element.dataset.reducedMotion = String(this.motion.matches);
    this.engine?.setActive(active);
    if (!active) this.engine?.renderStatic();
  }
}
