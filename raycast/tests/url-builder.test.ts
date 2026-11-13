import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildCommandURL,
  MAX_COMMAND_URL_LENGTH,
  validateAskText,
} from "../src/url-builder.ts";

test("buildCommandURL percent-encodes spaces and preserves literal pluses", () => {
  const url = buildCommandURL("ask", [["text", "客厅灯 +10%"]], "tok_1", "req_1");
  assert.equal(
    url,
    "menumijia://ask?text=%E5%AE%A2%E5%8E%85%E7%81%AF%20%2B10%25&id=req_1&token=tok_1",
  );
});

test("validateAskText rejects empty and >500 character inputs", () => {
  assert.deepEqual(validateAskText("   "), {
    ok: false,
    title: "Enter a command first",
  });
  const tooManyChars = validateAskText("a".repeat(501));
  assert.equal(tooManyChars.ok, false);
  if (!tooManyChars.ok) {
    assert.match(tooManyChars.message ?? "", /500 characters/);
  }
});

test("460 Chinese characters (<= 500 chars, > 4096 URL-encoded bytes) are rejected immediately", () => {
  const chineseText = "把".repeat(460);
  assert.equal(chineseText.length, 460);

  const check = validateAskText(chineseText);
  assert.equal(check.ok, false);
  if (!check.ok) {
    assert.equal(check.title, "Command is too long");
    assert.match(check.message ?? "", new RegExp(String(MAX_COMMAND_URL_LENGTH)));
  }

  assert.throws(
    () => buildCommandURL("ask", [["text", chineseText]], "token_abc", "req_123"),
    /4096/,
  );
});

test("normal Chinese command within 4096 encoded bytes passes", () => {
  const check = validateAskText("  把客厅吸顶灯调到 40%  ");
  assert.deepEqual(check, { ok: true, text: "把客厅吸顶灯调到 40%" });
});
