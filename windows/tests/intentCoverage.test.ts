import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { DelayPhrase, LocalIntentParser, UndoPhrase } from "../src/core/assistant.js";
import type { HomeScene, SmartDevice } from "../src/core/models.js";

/**
 * Windows half of item #8 of `docs/research/2026-11-23-deep-dive/00-SUMMARY.md` (R14).
 *
 * The zh-CN command corpus in `Tests/Fixtures/intent_coverage_corpus.json` is shared with
 * `Tests/MijiaCoreTests/IntentCoverageBaselineTests.swift`; this runner prints the same
 * category × local/model/none table for `LocalIntentParser` so the two platforms can be compared.
 *
 * 只跑不判: only corpus hygiene is asserted. The committed baseline
 * (`docs/research/2026-11-23-deep-dive/intent-coverage-baseline.md`) is written by the Swift run,
 * so the two runners cannot fight over one file; run this one to check Windows parity by eye.
 */

interface CoverageCorpus {
  readonly _meta: { readonly categories: readonly string[] };
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly utterances: ReadonlyArray<{ readonly category: string; readonly text: string }>;
}

/** Mirrors the Swift outcome, and the stage order of `runAssistantCommand`. */
type Outcome = "local" | "model" | "none";

const OUTCOMES: readonly Outcome[] = ["local", "model", "none"];

/** Timer cancel → voice undo → spoken delay → local parser → model. */
function classify(text: string, devices: readonly SmartDevice[], scenes: readonly HomeScene[]): Outcome {
  if (DelayPhrase.isCancel(text) || UndoPhrase.isUndo(text)) return "none";
  const utterance = DelayPhrase.extract(text)?.remainder ?? text;
  return LocalIntentParser.parse(utterance, devices, scenes) === null ? "model" : "local";
}

function loadCorpus(): CoverageCorpus {
  const path = resolve(process.cwd(), "../Tests/Fixtures/intent_coverage_corpus.json");
  return JSON.parse(readFileSync(path, "utf8")) as CoverageCorpus;
}

function percent(part: number, whole: number): string {
  if (whole === 0) return "—";
  return `${((part / whole) * 100).toFixed(1)}%`;
}

describe("intent coverage baseline (shared zh-CN corpus)", () => {
  it("classifies every utterance as local, model, or none and prints the table", () => {
    const corpus = loadCorpus();
    const categories = corpus._meta.categories;
    const utterances = corpus.utterances;

    assert.ok(corpus.devices.length > 0, "the corpus needs a fixed home to parse against");
    assert.ok(corpus.scenes.length > 0, "the corpus needs scenes for the scene category");
    assert.ok(
      utterances.length >= 150 && utterances.length <= 300,
      `corpus size ${utterances.length} is outside the 150–300 brief`
    );
    assert.equal(new Set(utterances.map((u) => u.text)).size, utterances.length, "duplicate utterances in the corpus");

    // Same hygiene check as the Swift runner: a category may not be used without being declared.
    const used = new Set(utterances.map((u) => u.category));
    assert.deepEqual(
      [...used].sort(),
      [...new Set(categories)].sort(),
      "a category is used but not declared in _meta.categories, or vice versa"
    );

    const rows = utterances.map((u) => ({
      category: u.category,
      text: u.text,
      outcome: classify(u.text, corpus.devices, corpus.scenes),
    }));
    const count = (predicate: (outcome: Outcome) => boolean): number =>
      rows.filter((row) => predicate(row.outcome)).length;

    // Totals must add up — the one invariant a recording-only runner can still assert.
    assert.equal(OUTCOMES.reduce((sum, outcome) => sum + count((o) => o === outcome), 0), rows.length);

    const nameWidth = Math.max(...categories.map((c) => c.length), 8);
    const pad = (text: string, width: number, right = false): string =>
      right ? text.padStart(width) : text.padEnd(width);
    const lines = [
      `intent coverage (windows) — ${rows.length} utterances, ${corpus.devices.length} devices`,
      `${pad("category", nameWidth)}  ${pad("local", 5, true)}  ${pad("model", 5, true)}  ${pad("none", 4, true)}  ${pad("total", 5, true)}  local%`,
    ];
    for (const category of categories) {
      const inCategory = rows.filter((row) => row.category === category);
      const local = inCategory.filter((row) => row.outcome === "local").length;
      lines.push(
        `${pad(category, nameWidth)}  ${pad(`${local}`, 5, true)}  ${pad(`${inCategory.filter((r) => r.outcome === "model").length}`, 5, true)}  ${pad(`${inCategory.filter((r) => r.outcome === "none").length}`, 4, true)}  ${pad(`${inCategory.length}`, 5, true)}  ${percent(local, inCategory.length)}`
      );
    }
    const local = count((o) => o === "local");
    lines.push(
      `${pad("total", nameWidth)}  ${pad(`${local}`, 5, true)}  ${pad(`${count((o) => o === "model")}`, 5, true)}  ${pad(`${count((o) => o === "none")}`, 4, true)}  ${pad(`${rows.length}`, 5, true)}  ${percent(local, rows.length)}`
    );
    console.log(lines.join("\n"));
  });
});
