#!/usr/bin/env python3
"""Enforce Windows Fluent 2 CSS curve tokens, exit-ghost surface parity, and layout clip invariants."""
from __future__ import annotations

from pathlib import Path
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
STYLES_PATH = ROOT / "windows" / "src" / "ui" / "styles.css"
RECONCILER_PATH = ROOT / "windows" / "src" / "ui" / "reconciler.ts"

RAW_EASE_RE = re.compile(r"(?<![-\w])(?:ease-in-out|ease-in|ease-out|ease)(?![-\w])")
GHOST_PAIR_RE = re.compile(r'\[\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\]')


def strip_css_comments_and_strings(css: str) -> str:
    out: list[str] = []
    i = 0
    n = len(css)
    while i < n:
        c = css[i]
        nxt = css[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "*":
            out.append("  ")
            i += 2
            while i < n and not (css[i] == "*" and (i + 1 < n and css[i + 1] == "/")):
                out.append("\n" if css[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
            continue
        if c in ("'", '"'):
            quote = c
            out.append(" ")
            i += 1
            while i < n:
                if css[i] == "\\":
                    out.append("  " if i + 1 < n else " ")
                    i += 2
                    continue
                if css[i] == quote:
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if css[i] == "\n" else " ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_ghost_renames(ts_src: str) -> list[tuple[str, str]]:
    marker = "GHOST_CLASS_RENAMES"
    start = ts_src.find(marker)
    if start < 0:
        return []
    bracket_open = ts_src.find("[", ts_src.find("=", start))
    if bracket_open < 0:
        return []
    depth = 0
    end = bracket_open
    while end < len(ts_src):
        if ts_src[end] == "[":
            depth += 1
        elif ts_src[end] == "]":
            depth -= 1
            if depth == 0:
                end += 1
                break
        end += 1
    return GHOST_PAIR_RE.findall(ts_src[bracket_open:end])


def iter_css_rules(clean_css: str) -> list[tuple[str, str]]:
    rules: list[tuple[str, str]] = []
    for match in re.finditer(r"([^{}]+)\{([^{}]*)\}", clean_css):
        selector = " ".join(match.group(1).split())
        body = " ".join(match.group(2).split())
        rules.append((selector, body))
    return rules


def check_sources(css_src: str, reconciler_src: str | None) -> list[str]:
    errors: list[str] = []
    clean_css = strip_css_comments_and_strings(css_src)

    for line_no, line in enumerate(clean_css.splitlines(), 1):
        hit = RAW_EASE_RE.search(line)
        if hit:
            errors.append(
                f"windows/src/ui/styles.css:{line_no}: 请使用 var(--ease-*) 曲线变量，禁止裸写 `{hit.group(0)}`"
            )

    if reconciler_src is not None:
        pairs = parse_ghost_renames(reconciler_src)
        if not pairs:
            errors.append("windows/src/ui/reconciler.ts: 未能解析 GHOST_CLASS_RENAMES")
        for live_cls, ghost_cls in pairs:
            selector_re = re.compile(r"\." + re.escape(ghost_cls) + r"(?![-\w])")
            if not selector_re.search(clean_css):
                errors.append(
                    f"windows/src/ui/styles.css: 缺少退场幽灵类 `.{ghost_cls}`（对应 reconciler.ts `{live_cls}`）"
                )

    rules = iter_css_rules(clean_css)
    has_fill_override = any(
        ".cc-tile-fill[style*=" in sel
        and "width: 100% !important" in body
        and "scaleX(var(--fill-scale" in body
        for sel, body in rules
    )
    if not has_fill_override:
        errors.append(
            "windows/src/ui/styles.css: `.cc-tile-fill[style*=\"--fill-scale\"]` 须同时保留 `width: 100% !important` 与 `scaleX(var(--fill-scale...))`"
        )

    has_subpage_unclip = any(
        ".is-subpage" in sel and ".cc-expander-clip" in sel and "overflow: visible" in body
        for sel, body in rules
    )
    if not has_subpage_unclip:
        errors.append(
            "windows/src/ui/styles.css: `.cc-tile.is-subpage .cc-expander-clip` 须保持 `overflow: visible` 以免裁切滑块气泡"
        )

    has_nowrap_btn = any(
        re.search(r"(?:^|,)\s*\.cc-btn(?:\s|,|$)", sel)
        and "white-space: nowrap" in body
        and "flex-shrink: 0" in body
        for sel, body in rules
    )
    if not has_nowrap_btn:
        errors.append(
            "windows/src/ui/styles.css: `.cc-btn` 须保留 `white-space: nowrap` 与 `flex-shrink: 0` 以免设置底栏折行"
        )

    return errors


def self_test() -> None:
    valid_css = """
    /* ease in a comment is ignored */
    :root { --ease-decelerate: cubic-bezier(0, 0, 0, 1); }
    .cc-sheet, .cc-sheet-ghost { content: "ease"; transition: transform 167ms var(--ease-decelerate); }
    .cc-tile-fill[style*="--fill-scale"] { width: 100% !important; transform: scaleX(var(--fill-scale, 1)); }
    .cc-tile.is-subpage .cc-expander-clip { overflow: visible; }
    .cc-btn, .cc-btn-primary { white-space: nowrap; flex-shrink: 0; }
    """
    valid_ts = 'const GHOST_CLASS_RENAMES = [["cc-sheet", "cc-sheet-ghost"]];'
    if check_sources(valid_css, valid_ts):
        raise SystemExit(f"self-test valid input failed: {check_sources(valid_css, valid_ts)}")

    raw_ease = valid_css + "\n.bad { transition: opacity 150ms ease-out; }\n"
    if not any("裸写 `ease-out`" in e for e in check_sources(raw_ease, valid_ts)):
        raise SystemExit("self-test failed to catch raw ease-out")

    missing_ghost_ts = 'const GHOST_CLASS_RENAMES = [["cc-sheet", "cc-sheet-ghost"], ["cc-menu", "cc-menu-ghost"]];'
    if not any(".cc-menu-ghost" in e for e in check_sources(valid_css, missing_ghost_ts)):
        raise SystemExit("self-test failed to catch missing ghost selector")

    clipped_subpage = valid_css.replace("overflow: visible;", "overflow: hidden;")
    if not any("cc-expander-clip" in e for e in check_sources(clipped_subpage, valid_ts)):
        raise SystemExit("self-test failed to catch clipped subpage expander")


def main() -> None:
    self_test()
    if not STYLES_PATH.is_file():
        return
    css_src = STYLES_PATH.read_text(encoding="utf-8")
    reconciler_src = RECONCILER_PATH.read_text(encoding="utf-8") if RECONCILER_PATH.is_file() else None
    errors = check_sources(css_src, reconciler_src)
    if errors:
        print("\n".join(f"❌ {err}" for err in errors), file=sys.stderr)
        sys.exit(1)
    print("✅ Windows Fluent 2 动效变量、退场幽灵类与防裁切规则检查通过")


if __name__ == "__main__":
    main()
