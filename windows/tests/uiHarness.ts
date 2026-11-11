import { Window } from "happy-dom";
import { installWindow } from "./dom.js";

let previousGlobalFetch: typeof globalThis.fetch | undefined;

function unstubbedFetchGuard(input: RequestInfo | URL): Promise<Response> {
  const target = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  return Promise.reject(
    new Error(`Unstubbed network fetch in UI test (${target}); stub __TAURI_INTERNALS__.invoke or fetch`),
  );
}

/** Focus starts on, so a guard does not follow happy-dom's default `hasFocus()`.
 * `stubInterval` replaces `setInterval` so `startTimerLoop` cannot fire.
 * Live `fetch` is rejected by default so a missing `__TAURI_INTERNALS__` stub fails in 1 ms instead of
 * polling a real cloud endpoint for minutes.
 */
export function mountTestWindow(options?: { stubInterval?: boolean; allowNetworkFetch?: boolean }): Window {
  const dom = new Window({ url: "http://localhost/" });
  previousGlobalFetch = globalThis.fetch;
  installWindow(dom);
  if (!options?.allowNetworkFetch) {
    Object.defineProperty(dom, "fetch", { value: unstubbedFetchGuard, configurable: true, writable: true });
    Object.defineProperty(globalThis, "fetch", { value: unstubbedFetchGuard, configurable: true, writable: true });
  }
  Object.defineProperty(dom.navigator, "languages", { value: ["zh-CN", "zh"], configurable: true });
  Object.defineProperty(dom.navigator, "language", { value: "zh-CN", configurable: true });
  document.body.innerHTML = '<div id="app"></div>';
  if (options?.stubInterval) {
    Object.defineProperty(dom, "setInterval", { value: () => 0, configurable: true });
  }
  setWindowFocused(true);
  return dom;
}

export async function closeTestWindow(dom: Window): Promise<void> {
  await dom.happyDOM.abort();
  dom.close();
  if (previousGlobalFetch !== undefined) {
    Object.defineProperty(globalThis, "fetch", { value: previousGlobalFetch, configurable: true, writable: true });
    previousGlobalFetch = undefined;
  }
}

export function setWindowFocused(focused: boolean): () => void {
  const previous = document.hasFocus.bind(document);
  document.hasFocus = () => focused;
  return () => {
    document.hasFocus = previous;
  };
}

/** happy-dom has no `CSS.escape`, which the layout gestures use to build tile selectors. */
export function installCssEscape(): () => void {
  Object.defineProperty(globalThis, "CSS", {
    value: { escape: (value: string) => value },
    configurable: true,
  });
  return () => Reflect.deleteProperty(globalThis, "CSS");
}
