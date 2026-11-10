import { Window } from "happy-dom";
import { installWindow } from "./dom.js";

/** Focus starts on, so a guard does not follow happy-dom's default `hasFocus()`.
 * `stubInterval` replaces `setInterval` so `startTimerLoop` cannot fire.
 */
export function mountTestWindow(options?: { stubInterval?: boolean }): Window {
  const dom = new Window({ url: "http://localhost/" });
  installWindow(dom);
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
