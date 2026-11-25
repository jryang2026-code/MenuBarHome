type IdleWindow = Window & {
  requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number;
  cancelIdleCallback?: (id: number) => void;
};

/** Runs `cb` when the browser is idle (or after `fallbackMs` without requestIdleCallback). Returns a cancel function. */
export function scheduleIdle(cb: () => void, timeoutMs: number, fallbackMs: number): () => void {
  const w = window as IdleWindow;
  if (w.requestIdleCallback) {
    const id = w.requestIdleCallback(cb, { timeout: timeoutMs });
    return () => w.cancelIdleCallback?.(id);
  }
  const timer = window.setTimeout(cb, fallbackMs);
  return () => window.clearTimeout(timer);
}
