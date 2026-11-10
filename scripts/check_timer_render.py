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

import re
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
            "startTimerLoop calls host.render() twice. The first flushes pendingCloudRender only "
            "after hasBlockingPanelInteraction() is false, and render() clears that flag. The "
            "second is the direct call CODING_STANDARDS.md section 16 allows while scheduled "
            "commands are queued, without the gesture check. The same statement also clears an "
            "expired undo row. Section 16 does not allow that undo paint on its own. "
            "queueBackgroundRender() would set the flag and leave the paint to a later tick.",
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


def is_ident_char(ch: str) -> bool:
    return ch.isalnum() or ch in "_$"


def skip_ws(src: str, code: bytearray, j: int, end: int) -> int:
    while j < end and code[j] and src[j] in " \t\r\n":
        j += 1
    return j


def render_word(src: str, code: bytearray, i: int, end: int) -> int | None:
    if not code[i] or not src.startswith("render", i):
        return None
    if i > 0 and is_ident_char(src[i - 1]):
        return None
    j = i + len("render")
    if j < end and code[j] and is_ident_char(src[j]):
        return None
    return j


def opens_call(src: str, code: bytearray, j: int, end: int) -> int | None:
    j = skip_ws(src, code, j, end)
    if j + 1 < end and src.startswith("?.", j) and code[j]:
        j = skip_ws(src, code, j + 2, end)
    if j < end and code[j] and src[j] == "(":
        return j
    return None


def render_calls(src: str, code: bytearray, start: int, end: int) -> list[int]:
    hits: list[int] = []
    i = start
    while i < end:
        if not code[i]:
            i += 1
            continue
        word = render_word(src, code, i, end)
        if word is not None:
            call = opens_call(src, code, word, end)
            if call is not None:
                hits.append(i)
                i = call + 1
                continue
        bracket = bracket_render_call(src, code, i, end)
        if bracket is not None:
            hits.append(i)
            i = bracket + 1
            continue
        i += 1
    return hits


def bracket_render_call(src: str, code: bytearray, i: int, end: int) -> int | None:
    if src[i] != "[" or not code[i]:
        return None
    j = skip_ws(src, code, i + 1, end)
    if j >= end or src[j] not in "'\"":
        return None
    quote = src[j]
    name_start = j + 1
    name_end = src.find(quote, name_start, end)
    if name_end < 0 or src[name_start:name_end] != "render":
        return None
    j = skip_ws(src, code, name_end + 1, end)
    if j >= end or not code[j] or src[j] != "]":
        return None
    if opens_call(src, code, j + 1, end) is None:
        return None
    return i


def alias_names(src: str, code: bytearray) -> set[str]:
    names: set[str] = set()
    pattern = re.compile(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]*)")
    access = re.compile(r"\.render\b|\[\s*['\"]render['\"]\s*\]")
    for match in pattern.finditer(src):
        if not code[match.start()]:
            continue
        expr_start = match.start(2)
        for found in access.finditer(match.group(2)):
            if code[expr_start + found.start()]:
                names.add(match.group(1))
                break
    return names


def alias_calls(src: str, code: bytearray, start: int, end: int, names: set[str]) -> list[int]:
    hits: list[int] = []
    for name in names:
        if name == "render":
            continue
        i = start
        while i < end:
            if (
                code[i]
                and src.startswith(name, i)
                and (i == 0 or not is_ident_char(src[i - 1]))
                and (i + len(name) >= end or not is_ident_char(src[i + len(name)]))
            ):
                call = opens_call(src, code, i + len(name), end)
                if call is not None:
                    hits.append(i)
                    i = call + 1
                    continue
            i += 1
    return hits


def bare_render_argument(src: str, code: bytearray, start: int, end: int) -> int | None:
    chars = [src[i] for i in range(start, end) if code[i]]
    text = "".join(chars).strip()
    raw = src[start:end]
    if text == "render" or text.endswith(".render"):
        return start
    if text.endswith("[]") and ('["render"]' in raw or "['render']" in raw):
        return start
    return None


def scan_source(path: str, src: str) -> list[tuple[str, int, str]]:
    code = code_mask(src)
    names = alias_names(src, code)
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
        calls = render_calls(src, code, start, end)
        calls.extend(index for index in alias_calls(src, code, start, end, names) if index not in calls)
        for call in calls:
            line_no, line = line_span(src, call)
            hits.append((path, line_no, normalize_line(line)))
        bare = bare_render_argument(src, code, start, end)
        if bare is not None and not calls:
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
        "optional call": (
            "setTimeout(() => {\n  host.render?.();\n}, 0);\n",
            ["host.render?.();"],
        ),
        "bracket call": (
            "setTimeout(() => {\n  host[\"render\"]();\n}, 0);\n",
            ["host[]();"],
        ),
        "single quote bracket": (
            "setTimeout(() => {\n  host['render']();\n}, 1);\n",
            ["host[]();"],
        ),
        "aliased call": (
            "const paint = host.render;\n"
            "setTimeout(() => {\n  paint();\n}, 0);\n",
            ["paint();"],
        ),
        "optional alias": (
            "let paint = this.render;\nsetTimeout(() => paint?.(), 0);\n",
            ["setTimeout(() => paint?.(), 0);"],
        ),
        "bracket alias": (
            "const paint = host[\"render\"];\nsetTimeout(() => {\n  paint();\n}, 0);\n",
            ["paint();"],
        ),
        "bare bracket argument": (
            "window.setTimeout(host[\"render\"], 0);\n",
            ["window.setTimeout(host[], 0);"],
        ),
        "string that names render is not an alias": (
            "const paint = \"host.render\";\nsetTimeout(() => { paint(); }, 0);\n",
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
