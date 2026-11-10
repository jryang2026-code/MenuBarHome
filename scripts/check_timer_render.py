#!/usr/bin/env python3
"""Flag a timer callback that calls render() instead of queueBackgroundRender().

Node's panel defers background paints with queueBackgroundRender(). A setTimeout,
setInterval, or requestAnimationFrame callback that calls render() directly
rebuilds the panel under a gesture. startTimerLoop is the exception named in
CODING_STANDARDS.md section 16, and its two calls are allowlisted here with the
reason. A new call fails this check. An allowlisted call that disappears fails
too, so the reason cannot outlive the code.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
SCAN_ROOT = ROOT / "windows" / "src"
TIMERS = ("setTimeout", "setInterval", "requestAnimationFrame")

ALLOWLIST: dict[str, dict[str, tuple[int, str]]] = {
    "windows/src/ui/appLifecycle.ts": {
        "host.render();": (
            2,
            "startTimerLoop's first host.render() flushes pendingCloudRender after the gesture "
            "check. render() clears the flag. The second paints undo expiry or a due scheduled "
            "command during a gesture. queueBackgroundRender() there would set the flag and leave "
            "the paint to a later tick. CODING_STANDARDS.md section 16 allows that direct call.",
        ),
    },
}


def code_mask(src: str) -> bytearray:
    code = bytearray(len(src))
    scan_code(src, 0, len(src), code)
    return code


def scan_code(src: str, i: int, end: int, code: bytearray) -> int:
    while i < end:
        c = src[i]
        nxt = src[i + 1] if i + 1 < end else ""
        if c == "/" and nxt == "/":
            i += 2
            while i < end and src[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i + 1 < end and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i = min(end, i + 2)
            continue
        if c in "'\"":
            i = skip_quoted(src, i, end, c)
            continue
        if c == "`":
            i = skip_template(src, i, end, code)
            continue
        code[i] = 1
        i += 1
    return i


def skip_quoted(src: str, i: int, end: int, quote: str) -> int:
    i += 1
    while i < end:
        if src[i] == "\\":
            i += 2
            continue
        if src[i] == quote:
            return i + 1
        i += 1
    return end


def skip_template(src: str, i: int, end: int, code: bytearray) -> int:
    i += 1
    while i < end:
        if src[i] == "\\":
            i += 2
            continue
        if src[i] == "`":
            return i + 1
        if src[i] == "$" and i + 1 < end and src[i + 1] == "{":
            code[i] = 1
            code[i + 1] = 1
            i = scan_template_expr(src, i + 2, end, code)
            continue
        i += 1
    return end


def scan_template_expr(src: str, i: int, end: int, code: bytearray) -> int:
    depth = 1
    while i < end and depth:
        c = src[i]
        nxt = src[i + 1] if i + 1 < end else ""
        if c == "/" and nxt == "/":
            i += 2
            while i < end and src[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i + 1 < end and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i = min(end, i + 2)
            continue
        if c in "'\"":
            i = skip_quoted(src, i, end, c)
            continue
        if c == "`":
            i = skip_template(src, i, end, code)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        code[i] = 1
        i += 1
    return i


def first_argument(src: str, code: bytearray, open_paren: int) -> tuple[int, int] | None:
    i = open_paren + 1
    n = len(src)
    start = i
    paren = bracket = brace = 0
    while i < n:
        if not code[i]:
            i += 1
            continue
        c = src[i]
        if c == "(":
            paren += 1
        elif c == ")":
            if paren == bracket == brace == 0:
                return (start, i)
            paren = max(0, paren - 1)
        elif c == "[":
            bracket += 1
        elif c == "]":
            bracket = max(0, bracket - 1)
        elif c == "{":
            brace += 1
        elif c == "}":
            brace = max(0, brace - 1)
        elif c == "," and paren == bracket == brace == 0:
            return (start, i)
        i += 1
    return None


def line_span(src: str, index: int) -> tuple[int, str]:
    line_start = src.rfind("\n", 0, index) + 1
    line_end = src.find("\n", index)
    if line_end < 0:
        line_end = len(src)
    line_no = src.count("\n", 0, index) + 1
    return line_no, src[line_start:line_end]


def normalize_line(line: str) -> str:
    without_comment = []
    code = code_mask(line)
    for index, char in enumerate(line):
        if code[index]:
            without_comment.append(char)
    return " ".join("".join(without_comment).split())


def render_calls(src: str, code: bytearray, start: int, end: int) -> list[int]:
    hits: list[int] = []
    i = start
    while i < end:
        if not code[i]:
            i += 1
            continue
        if src.startswith("render", i) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$")):
            j = i + len("render")
            while j < end and code[j] and src[j] in " \t\r\n":
                j += 1
            if j < end and code[j] and src[j] == "(":
                hits.append(i)
                i = j + 1
                continue
        i += 1
    return hits


def bare_render_argument(src: str, code: bytearray, start: int, end: int) -> int | None:
    chars = [src[i] for i in range(start, end) if code[i]]
    text = "".join(chars).strip()
    if text == "render" or text.endswith(".render"):
        return start
    return None


def scan_source(path: str, src: str) -> list[tuple[str, int, str]]:
    code = code_mask(src)
    hits: list[tuple[str, int, str]] = []
    i = 0
    n = len(src)
    while i < n:
        if not code[i]:
            i += 1
            continue
        matched = None
        for name in TIMERS:
            if src.startswith(name, i) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$")):
                after = i + len(name)
                j = after
                while j < n and code[j] and src[j] in " \t\r\n":
                    j += 1
                if j < n and code[j] and src[j] == "(":
                    matched = j
                break
        if matched is None:
            i += 1
            continue
        arg = first_argument(src, code, matched)
        if arg is None:
            i = matched + 1
            continue
        start, end = arg
        for call in render_calls(src, code, start, end):
            line_no, line = line_span(src, call)
            hits.append((path, line_no, normalize_line(line)))
        bare = bare_render_argument(src, code, start, end)
        if bare is not None and not render_calls(src, code, start, end):
            line_no, line = line_span(src, bare)
            hits.append((path, line_no, normalize_line(line)))
        i = end
    return hits


def scan_tree() -> list[tuple[str, int, str]]:
    hits: list[tuple[str, int, str]] = []
    for path in sorted(SCAN_ROOT.rglob("*")):
        if path.suffix not in {".ts", ".js"} or not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        hits.extend(scan_source(rel, path.read_text(encoding="utf-8")))
    return hits


def classify(hits: list[tuple[str, int, str]]) -> tuple[list[str], list[str]]:
    remaining = {path: dict(entries) for path, entries in ALLOWLIST.items()}
    unexpected: list[str] = []
    for path, line_no, text in hits:
        allowed = remaining.get(path, {}).get(text)
        if allowed is None:
            unexpected.append(f"{path}:{line_no}: {text}")
            continue
        count, reason = allowed
        if count <= 0:
            unexpected.append(f"{path}:{line_no}: {text}")
            continue
        remaining[path][text] = (count - 1, reason)
    stale: list[str] = []
    for path, entries in remaining.items():
        for text, (count, reason) in entries.items():
            if count != 0:
                stale.append(f"{path}: 允许了 {count} 处不存在的 `{text}`（{reason}）")
    return unexpected, stale


def self_test() -> None:
    cases = {
        "two direct calls": (
            "export function startTimerLoop() {\n"
            "  window.setInterval(() => {\n"
            "    if (flag) {\n"
            "      host.render();\n"
            "    }\n"
            "    if (changed) {\n"
            "      host.render();\n"
            "    }\n"
            "  }, 1000);\n"
            "}\n",
            ["host.render();", "host.render();"],
        ),
        "queue helper": (
            "window.setTimeout(() => {\n  this.queueBackgroundRender();\n}, 10);\n",
            [],
        ),
        "render after the timer": (
            "hide() {\n"
            "  this.timer = window.setTimeout(() => {\n"
            "    if (this.hidden) this.close();\n"
            "  }, this.ms);\n"
            "  this.host.render();\n"
            "}\n",
            [],
        ),
        "comment and string": (
            "window.setTimeout(() => {\n"
            "  // host.render();\n"
            "  const s = \"host.render()\";\n"
            "  this.queueBackgroundRender();\n"
            "}, 0);\n",
            [],
        ),
        "expression arrow": (
            "window.setTimeout(() => this.render(), 0);\n",
            ["window.setTimeout(() => this.render(), 0);"],
        ),
        "identifier callback": (
            "window.setTimeout(finish, ms);\nthis.render();\n",
            [],
        ),
        "passed method": (
            "window.setTimeout(this.render, 0);\n",
            ["window.setTimeout(this.render, 0);"],
        ),
        "template text is not a call": (
            "setTimeout(() => {\n  const label = `host.render()`;\n}, 1);\n",
            [],
        ),
        "template expression is a call": (
            "setTimeout(() => {\n  const label = `wait ${host.render()}`;\n}, 1);\n",
            ["const label = ${host.render()};"],
        ),
        "animation frame": (
            "requestAnimationFrame(() => {\n  this.render();\n});\n",
            ["this.render();"],
        ),
        "function expression": (
            "setInterval(function () {\n  host.render();\n}, 1000);\n",
            ["host.render();"],
        ),
        "string that looks like a timer": (
            "const sample = \"setTimeout(() => { host.render(); }, 0)\";\n",
            [],
        ),
        "nested parens before render outside": (
            "window.setTimeout(() => {\n  suppress = false;\n}, 0);\n"
            "host.render();\n",
            [],
        ),
    }
    for name, (src, expected) in cases.items():
        got = [text for _, _, text in scan_source("fixture.ts", src)]
        if got != expected:
            raise SystemExit(f"self-test {name}: got {got}, expected {expected}")

    allowed_hit = [("windows/src/ui/appLifecycle.ts", 1, "host.render();")] * 2
    unexpected, stale = classify(allowed_hit)
    if unexpected or stale:
        raise SystemExit(f"self-test allowlist consume: {unexpected} {stale}")
    unexpected, stale = classify(allowed_hit + [("windows/src/ui/app.ts", 9, "this.render();")])
    if not unexpected or stale:
        raise SystemExit("self-test allowlist should reject a new call")
    unexpected, stale = classify([("windows/src/ui/appLifecycle.ts", 1, "host.render();")])
    if not stale:
        raise SystemExit("self-test allowlist should reject a missing call")


def main() -> None:
    self_test()
    hits = scan_tree()
    if "--report" in sys.argv:
        for path, line_no, text in hits:
            print(f"{path}:{line_no}: {text}")
        print(f"hits {len(hits)}")
        return
    unexpected, stale = classify(hits)
    if unexpected or stale:
        print("❌ 定时器回调直接调用了 render()。后台刷新要用 queueBackgroundRender()。", file=sys.stderr)
        for item in unexpected:
            print(f"  {item}", file=sys.stderr)
        for item in stale:
            print(f"  过期的允许项：{item}", file=sys.stderr)
        raise SystemExit(1)
    reasons = []
    for path, entries in ALLOWLIST.items():
        for text, (count, reason) in entries.items():
            reasons.append(f"{path} `{text}` × {count}：{reason}")
    print(f"✅ 定时器回调没有未说明的 render()（已注明 {len(hits)} 处）。")
    for reason in reasons:
        print(f"   {reason}")


if __name__ == "__main__":
    main()
