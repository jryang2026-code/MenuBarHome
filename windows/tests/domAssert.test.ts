import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { assertMissing, assertPresent } from "./dom.js";

function button(): HTMLButtonElement {
  const node = document.createElement("button");
  node.id = "btn-undo";
  node.textContent = "x".repeat(50_000);
  return node;
}

describe("DOM assertions", () => {
  it("treats null and undefined as missing", () => {
    assertMissing(null);
    assertMissing(undefined);
  });

  it("names the element and returns immediately when a node is still there", () => {
    const node = button();
    const started = performance.now();
    assert.throws(
      () => assertMissing(node, "the undo button should be gone"),
      (error: unknown) => {
        assert.ok(error instanceof assert.AssertionError);
        assert.match(error.message, /the undo button should be gone/);
        assert.match(error.message, /<button#btn-undo>/);
        assert.equal(error.actual, "<button#btn-undo>");
        assert.equal(error.message.includes("xxxxx"), false);
        assert.ok(error.message.length < 500);
        return true;
      },
    );
    assert.ok(performance.now() - started < 200, "assertMissing walked the node");
  });

  it("accepts a node and rejects null or undefined without inspecting a node", () => {
    const node = button();
    assertPresent(node);
    const started = performance.now();
    assert.throws(
      () => assertPresent(null, "the hold button should exist"),
      (error: unknown) => {
        assert.ok(error instanceof assert.AssertionError);
        assert.match(error.message, /the hold button should exist/);
        assert.equal(error.actual, "null");
        return true;
      },
    );
    assert.throws(
      () => assertPresent(undefined),
      (error: unknown) => {
        assert.ok(error instanceof assert.AssertionError);
        assert.equal(error.actual, "undefined");
        return true;
      },
    );
    assert.ok(performance.now() - started < 200, "assertPresent walked a node");
  });
});
