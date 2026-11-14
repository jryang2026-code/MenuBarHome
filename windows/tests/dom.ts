import assert from "node:assert/strict";
import { Window } from "happy-dom";

export function installWindow(dom: Window): void {
  Object.defineProperties(globalThis, {
    window: { value: dom, configurable: true },
    document: { value: dom.document, configurable: true },
    localStorage: { value: dom.localStorage, configurable: true },
    Event: { value: dom.Event, configurable: true },
  });
}

function describeNode(node: object): string {
  const tag = "tagName" in node && typeof node.tagName === "string" ? node.tagName.toLowerCase() : "";
  if (tag) {
    const id = "id" in node && typeof node.id === "string" && node.id !== "" ? `#${node.id}` : "";
    return `<${tag}${id}>`;
  }
  if ("nodeName" in node && typeof node.nodeName === "string") return node.nodeName;
  return "node";
}

/** Do not pass the node to `assert.equal`. Its diff runs `util.inspect` with getters,
 * and that walk does not return on a happy-dom node, so `node --test` hangs.
 */
export function assertMissing(node: Node | null | undefined, message?: string): void {
  if (node == null) return;
  const found = describeNode(node);
  throw new assert.AssertionError({
    message: message ? `${message} (found ${found})` : `expected no node, found ${found}`,
    operator: "assertMissing",
    actual: found,
    expected: "null",
  });
}

installWindow(new Window());
