import type { CameraLens } from "../models.js";

const secondLensModels = new Set([
  "isa.camera.500dh",
  "isa.camera.hlmax",
  "chuangmi.camera.72ac1",
  "xiaomi.camera.082ac1",
]);

const negationMarkers = ["不是", "没有", "不要", "并非", "非", "无", "not ", "not-", "non-", "non ", "no ", "n't "];

function isNegated(prefix: string): boolean {
  const text = prefix.toLowerCase();
  return negationMarkers.some((marker) => text.endsWith(marker));
}

function isAsciiWord(char: string): boolean {
  return /^[A-Za-z0-9]$/.test(char);
}

function containsAffirmedPhrase(name: string, phrase: string): boolean {
  let from = 0;
  while (from <= name.length - phrase.length) {
    const index = name.indexOf(phrase, from);
    if (index < 0) return false;
    if (!isNegated(name.slice(0, index))) return true;
    from = index + phrase.length;
  }
  return false;
}

function containsAffirmedWord(name: string, word: string): boolean {
  const haystack = name.toLowerCase();
  const needle = word.toLowerCase();
  let from = 0;
  while (from <= haystack.length - needle.length) {
    const index = haystack.indexOf(needle, from);
    if (index < 0) return false;
    const before = index === 0 ? "" : haystack.charAt(index - 1);
    const afterIndex = index + needle.length;
    const after = afterIndex >= haystack.length ? "" : haystack.charAt(afterIndex);
    const beforeOK = before === "" || !isAsciiWord(before);
    const afterOK = after === "" || !isAsciiWord(after);
    if (beforeOK && afterOK && !isNegated(haystack.slice(0, index))) return true;
    from = index + needle.length;
  }
  return false;
}

/** A whole word or a known phrase. `Individual` and `不是双摄` are one lens. */
function nameSelectsSecondLens(name: string): boolean {
  return containsAffirmedPhrase(name, "双镜头")
    || containsAffirmedPhrase(name, "雙鏡頭")
    || containsAffirmedPhrase(name, "双摄")
    || containsAffirmedPhrase(name, "雙攝")
    || containsAffirmedWord(name, "dual");
}

/** Mirrors the macOS CameraLensCatalog so the shared golden corpus catches drift. */
export function cameraLensesFor(model: string, name = ""): readonly CameraLens[] {
  const normalized = model.trim().toLowerCase();
  if (!secondLensModels.has(normalized) && !nameSelectsSecondLens(name)) return [];
  return [
    { role: "main", channel: 0 },
    { role: "secondary", channel: 1 },
  ];
}
