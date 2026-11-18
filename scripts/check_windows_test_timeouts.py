#!/usr/bin/env python3
"""Reject sub-2-second waitFor deadlines in Windows tests: they flake on slow CI runners."""
from __future__ import annotations

from pathlib import Path
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
TESTS_GLOB = "windows/tests/**/*.ts"
MIN_TIMEOUT_MS = 2000
WAITFOR_RE = re.compile(r"(?<![A-Za-z0-9_$])waitFor(?![A-Za-z0-9_$])")
FUNC_BEFORE_RE = re.compile(r"\b(?:async\s+)?function\s*$")
NUMERIC_LITERAL_RE = re.compile(r"^[0-9](?:_?[0-9])*$")
PARAM_NUMERIC_DEFAULT_RE = re.compile(r"=\s*([0-9][0-9_]*)\s*$")
PARAM_NAME_RE = re.compile(r"^\s*([A-Za-z_$][A-Za-z0-9_$]*)")


def mask_comments_and_strings(src: str) -> str:
    """Blank out comments and string bodies while keeping offsets and newlines intact."""
    out = list(src)
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and nxt == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                out[i] = "\n" if src[i] == "\n" else " "
                i += 1
            if i < n:
                out[i] = out[i + 1] = " "
                i += 2
            continue
        if c in ("'", '"', "`"):
            quote = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    out[i] = " "
                    if i + 1 < n:
                        out[i + 1] = " "
                    i += 2
                    continue
                if src[i] == quote:
                    i += 1
                    break
                out[i] = "\n" if src[i] == "\n" else " "
                i += 1
            continue
        i += 1
    return "".join(out)


def read_paren_spans(masked: str, open_idx: int) -> list[tuple[int, int]]:
    """Top-level comma-separated spans of the (...) that opens at open_idx.

    Depth counting ignores commas inside nested calls/brackets; comments and
    string bodies were already blanked, so their commas cannot split arguments.
    """
    depth = 0
    spans: list[tuple[int, int]] = []
    seg_start = open_idx + 1
    i = open_idx
    n = len(masked)
    while i < n:
        c = masked[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth <= 0:
                spans.append((seg_start, i))
                return spans
        elif c == "," and depth == 1:
            spans.append((seg_start, i))
            seg_start = i + 1
        i += 1
    spans.append((seg_start, n))
    return spans


def span_head(masked: str, span: tuple[int, int]) -> int:
    # Index of the first non-whitespace char of a span (its own line, not the comma's).
    seg_start, seg_end = span
    lead = len(masked[seg_start:seg_end]) - len(masked[seg_start:seg_end].lstrip())
    return seg_start + lead


def line_of(masked: str, index: int) -> int:
    return masked.count("\n", 0, index) + 1


def scan_source(src: str, label: str) -> list[str]:
    masked = mask_comments_and_strings(src)
    errors: list[str] = []
    for match in WAITFOR_RE.finditer(masked):
        pos = match.start()
        is_decl = bool(FUNC_BEFORE_RE.search(masked[max(0, pos - 40) : pos]))
        i = match.end()
        while i < len(masked) and masked[i] in " \t\r\n":
            i += 1
        if i >= len(masked) or masked[i] != "(":
            continue
        spans = read_paren_spans(masked, i)
        if is_decl:
            for seg_start, seg_end in spans:
                seg = masked[seg_start:seg_end].strip()
                default = PARAM_NUMERIC_DEFAULT_RE.search(seg)
                if not default or (default.start() > 0 and seg[default.start() - 1] == ">"):
                    continue  # `=>` type arrows are not defaults.
                if int(default.group(1).replace("_", "")) >= MIN_TIMEOUT_MS:
                    continue
                name = PARAM_NAME_RE.match(seg)
                errors.append(
                    f"{label}:{line_of(masked, span_head(masked, (seg_start, seg_end)))}: waitFor 帮手参数 "
                    f"`{name.group(1) if name else '?'}` 默认 {default.group(1)}ms 低于 {MIN_TIMEOUT_MS}ms；"
                    f"请改用延迟 promise 或信号驱动等待，或把默认值提到 {MIN_TIMEOUT_MS}ms"
                )
            continue
        if len(spans) < 2:
            continue  # No explicit timeout argument; the helper default applies.
        arg = masked[spans[1][0] : spans[1][1]].strip()
        if not NUMERIC_LITERAL_RE.match(arg):
            continue  # A message string or a non-literal expression.
        if int(arg.replace("_", "")) >= MIN_TIMEOUT_MS:
            continue
        errors.append(
            f"{label}:{line_of(masked, span_head(masked, spans[1]))}: waitFor 显式超时 {arg}ms 低于 {MIN_TIMEOUT_MS}ms"
            f"（慢 runner 上必抖）；请改用延迟 promise 或信号驱动等待；若只是等待上限，删掉该参数用默认 {MIN_TIMEOUT_MS}ms 截止"
        )
    return errors


def check_tree(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for path in sorted((root / "windows" / "tests").rglob("*.ts")):
        label = path.relative_to(root).as_posix()
        errors.extend(scan_source(path.read_text(encoding="utf-8"), label))
    return errors


def main() -> None:
    errors = check_tree(ROOT)
    if errors:
        print("\n".join(f"❌ {err}" for err in errors), file=sys.stderr)
        sys.exit(1)
    print(f"✅ {TESTS_GLOB} 的 waitFor 超时下限（{MIN_TIMEOUT_MS}ms）检查通过")


if __name__ == "__main__":
    main()
