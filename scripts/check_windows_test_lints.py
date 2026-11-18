#!/usr/bin/env python3
"""Windows 测试里墙钟等待的静态门禁。

规则 A（禁新增裸墙钟长睡眠）：拦截 windows/tests 里数字字面量延迟 >= 100 ms 的
裸 `setTimeout(...)` 调用。慢 CI 机器的事件循环抖动正是 #235 修过的根因；等待要
用信号量式的 waitFor(predicate)，不要睡墙钟。测试替身的方法定义（形如
`public setTimeout(handler, delayMs)`，延迟不是数字字面量）天然不命中；历史遗留按
文件钉在 LEGACY_BLIND_SLEEP_CEILING，只减不增。

规则 B（禁新增亚秒级短上限 waitFor）：拦截 `waitFor(predicate, <timeoutMs>)`
第二参传 < 1000 ms 正整数字面量的调用，慢机器上极易偶发超时。历史遗留钉在
LEGACY_SHORT_WAITFOR_CEILING，任何新增立即红灯。

词法掩码沿用 scripts/check_timer_render.py：注释、字符串与模板字面量里的伪匹配
不计。`--report` 打印原始命中用于校准棘轮；`--self-test` 跑内置离线自检。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
SCAN_ROOT = ROOT / "windows" / "tests"

BLIND_SLEEP_MIN_MS = 100
SHORT_WAITFOR_MAX_MS = 999

Hit = tuple[str, int, str]
Allowlist = dict[str, dict[str, tuple[int, str]]]
RatchetCeiling = dict[str, int]

# 假句柄赋值：模拟小米摄像头还藏在 120 秒保活窗口里，回调体为空，不是等墙钟。
ALLOWLIST: Allowlist = {
    "windows/tests/aiAndSessionParity.test.ts": {
        "app.cameraLive.liveCameraKeepAliveTimer = window.setTimeout(() => {}, 120_000);": (
            1,
            "给 liveCameraKeepAliveTimer 赋一个空回调的假句柄，模拟摄像头 Sign Out 时还在 "
            "120 秒保活窗口内（见注释），不是测试在等墙钟。",
        ),
    },
}

LEGACY_BLIND_SLEEP_CEILING: RatchetCeiling = {
    "windows/tests/classicMotionAndReconciler.test.ts": 1,
    "windows/tests/companionBridge.test.ts": 1,
    "windows/tests/haDomainsAndLocks.test.ts": 1,
    "windows/tests/ui.test.ts": 13,
}

LEGACY_SHORT_WAITFOR_CEILING: RatchetCeiling = {
    "windows/tests/w2UndoGrokCam.test.ts": 1,
}


# ---------------------------------------------------------------------------
# TS/JS lexer: code_mask marks which bytes are real code (1) versus comments,
# strings, template literal text, and regex bodies (0). Ported from
# scripts/check_timer_render.py, which documents the regex-vs-division rules.
# ---------------------------------------------------------------------------

_REGEX_WORDS = frozenset({
    "return", "throw", "case", "else", "do", "typeof", "void", "delete",
    "yield", "await", "in", "of", "instanceof", "new", "extends",
})


def skip_regex(src: str, i: int, end: int) -> int:
    i += 1
    in_class = False
    while i < end:
        c = src[i]
        if c in "\n\r":
            return i
        if c == "\\":
            i += 2 if i + 1 < end else 1
            continue
        if in_class:
            if c == "]":
                in_class = False
            i += 1
            continue
        if c == "[":
            in_class = True
            i += 1
            continue
        if c == "/":
            i += 1
            while i < end and src[i].isascii() and src[i].isalpha():
                i += 1
            return i
        i += 1
    return end


def scan_tokens(src: str, i: int, end: int, code: bytearray, can_regex: bool, stop_on_brace: bool) -> tuple[int, bool]:
    depth = 0
    while i < end:
        c = src[i]
        nxt = src[i + 1] if i + 1 < end else ""
        if c in " \t\r\n":
            code[i] = 1
            i += 1
            continue
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
        if c == "/" and can_regex:
            i = skip_regex(src, i, end)
            can_regex = False
            continue
        if c in "'\"":
            i = skip_quoted(src, i, end, c)
            can_regex = False
            continue
        if c == "`":
            i = skip_template(src, i, end, code)
            can_regex = False
            continue
        if c.isalpha() or c in "_$":
            j = i + 1
            while j < end and (src[j].isalnum() or src[j] in "_$"):
                j += 1
            word = src[i:j]
            for index in range(i, j):
                code[index] = 1
            can_regex = word in _REGEX_WORDS
            i = j
            continue
        if c.isdigit():
            while i < end and (src[i].isalnum() or src[i] in "._"):
                code[i] = 1
                i += 1
            can_regex = False
            continue
        if c == "}" and stop_on_brace and depth == 0:
            return i, can_regex
        code[i] = 1
        if c == "{":
            depth += 1
            can_regex = True
            i += 1
            continue
        if c == "}":
            depth = max(0, depth - 1)
            can_regex = False
            i += 1
            continue
        if c == "?":
            if nxt == ".":
                code[i + 1] = 1
                can_regex = False
                i += 2
                continue
            if nxt == "?":
                code[i + 1] = 1
                can_regex = True
                i += 2
                continue
            can_regex = True
            i += 1
            continue
        if c == "=" and nxt == ">":
            code[i + 1] = 1
            can_regex = True
            i += 2
            continue
        if c == ".":
            can_regex = False
            i += 1
            continue
        if c in ")]}":
            can_regex = False
            i += 1
            continue
        can_regex = True
        i += 1
    return i, can_regex


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
    i, _can_regex = scan_tokens(src, i, end, code, can_regex=True, stop_on_brace=True)
    if i < end and src[i] == "}":
        code[i] = 1
        return i + 1
    return i


def code_mask(src: str) -> bytearray:
    code = bytearray(len(src))
    scan_tokens(src, 0, len(src), code, can_regex=True, stop_on_brace=False)
    return code


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


# ---------------------------------------------------------------------------
# Finders
# ---------------------------------------------------------------------------

_NUMERIC_LITERAL_RE = re.compile(r"[0-9][0-9_]*")


def is_ident_char(ch: str) -> bool:
    return ch.isalnum() or ch in "_$"


def skip_ws(src: str, code: bytearray, j: int, end: int) -> int:
    while j < end and code[j] and src[j] in " \t\r\n":
        j += 1
    return j


def call_argument_spans(src: str, code: bytearray, open_paren: int) -> list[tuple[int, int]] | None:
    i = open_paren + 1
    n = len(src)
    start = i
    paren = bracket = brace = 0
    spans: list[tuple[int, int]] = []
    while i < n:
        if not code[i]:
            i += 1
            continue
        c = src[i]
        if c == "(":
            paren += 1
        elif c == ")":
            if paren == bracket == brace == 0:
                spans.append((start, i))
                return spans
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
            spans.append((start, i))
            start = i + 1
        i += 1
    return None


def numeric_literal_ms(src: str, code: bytearray, span: tuple[int, int]) -> int | None:
    text = "".join(src[i] for i in range(span[0], span[1]) if code[i]).strip()
    if not _NUMERIC_LITERAL_RE.fullmatch(text):
        return None
    return int(text.replace("_", ""))


def call_hits(path: str, src: str, name: str, *, min_ms: int | None, max_ms: int | None) -> list[Hit]:
    """Report `<name>(..., delay)` call sites whose delay is a numeric literal
    within [min_ms, max_ms]. Only literal delays count, so test-double method
    definitions (`public setTimeout(handler, delayMs)`) never match.
    """
    code = code_mask(src)
    hits: list[Hit] = []
    i = 0
    n = len(src)
    while i < n:
        if not code[i] or not src.startswith(name, i):
            i += 1
            continue
        if i > 0 and is_ident_char(src[i - 1]):
            i += 1
            continue
        after = i + len(name)
        if after >= n or not code[after] or is_ident_char(src[after]):
            i += 1
            continue
        j = skip_ws(src, code, after, n)
        if j + 1 < n and src.startswith("?.", j) and code[j]:
            j = skip_ws(src, code, j + 2, n)
        if j >= n or not code[j] or src[j] != "(":
            i += 1
            continue
        spans = call_argument_spans(src, code, j)
        if not spans or len(spans) < 2:
            i = j + 1
            continue
        delay_ms = numeric_literal_ms(src, code, spans[1])
        if delay_ms is None:
            i = j + 1
            continue
        if min_ms is not None and delay_ms < min_ms:
            i = j + 1
            continue
        if max_ms is not None and delay_ms > max_ms:
            i = j + 1
            continue
        line_no, line = line_span(src, i)
        hits.append((path, line_no, normalize_line(line)))
        i = j + 1
    return hits


def blind_sleeps(path: str, src: str) -> list[Hit]:
    if "setTimeout" not in src:
        return []
    return call_hits(path, src, "setTimeout", min_ms=BLIND_SLEEP_MIN_MS, max_ms=None)


def short_waitfors(path: str, src: str) -> list[Hit]:
    if "waitFor" not in src:
        return []
    return call_hits(path, src, "waitFor", min_ms=None, max_ms=SHORT_WAITFOR_MAX_MS)


# ---------------------------------------------------------------------------
# Allowlist + ratchet classification (ported from check_swift_harness_lints.py:
# ceilings only shrink; an over-limit file fails, a file left below its ceiling
# fails until the ceiling is lowered or removed).
# ---------------------------------------------------------------------------

def classify(
    hits: list[Hit],
    allowlist: Allowlist,
    ratchet_ceiling: RatchetCeiling | None = None,
) -> tuple[list[str], list[str]]:
    remaining = {path: dict(entries) for path, entries in allowlist.items()}
    ceilings = ratchet_ceiling or {}
    unallowed: dict[str, list[tuple[int, str]]] = {}
    unexpected: list[str] = []
    for path, line, text in hits:
        allowed = remaining.get(path, {}).get(text)
        if allowed is not None and allowed[0] > 0:
            remaining[path][text] = (allowed[0] - 1, allowed[1])
        else:
            unallowed.setdefault(path, []).append((line, text))
    stale: list[str] = [
        f"{path}: 允许了 {cnt} 处不存在的 `{text}`（{reason}）"
        for path, entries in remaining.items()
        for text, (cnt, reason) in entries.items()
        if cnt != 0
    ]
    for path, ceiling in sorted(ceilings.items()):
        if ceiling <= 0:
            stale.append(f"{path}: 历史上限必须 > 0（当前为 {ceiling}），清零后请直接移除该条目")
    for path in sorted(set(unallowed) | set(ceilings)):
        file_hits = unallowed.get(path, [])
        actual, ceiling = len(file_hits), ceilings.get(path, 0)
        if ceiling <= 0:
            unexpected.extend(f"{path}:{line}: {text}" for line, text in file_hits)
        elif actual > ceiling:
            unexpected.extend(
                f"{path}:{line}: {text}（文件共 {actual} 处，超出历史上限 {ceiling}）"
                for line, text in file_hits
            )
        elif actual < ceiling:
            stale.append(f"{path}: 实际剩余 {actual} 处（历史上限 {ceiling}），请同步下调或移除对应 CEILING 条目")
    return unexpected, stale


def scan_tree(finder) -> list[Hit]:
    if not SCAN_ROOT.is_dir():
        return []
    hits: list[Hit] = []
    for path in sorted(SCAN_ROOT.rglob("*")):
        if path.suffix not in {".ts", ".mjs", ".js"} or not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        hits.extend(finder(rel, path.read_text(encoding="utf-8")))
    return hits


def report(title: str, hits: list[Hit], allowlist: Allowlist, ceilings: RatchetCeiling) -> bool:
    unexpected, stale = classify(hits, allowlist, ceilings)
    if unexpected or stale:
        print(f"❌ {title}", file=sys.stderr)
        for item in unexpected:
            print(f"  {item}", file=sys.stderr)
        for item in stale:
            print(f"  过期的允许项：{item}", file=sys.stderr)
        return False
    print(f"✅ {title}（已注明 {len(hits)} 处）。")
    return True


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _expect_hits(src: str, name: str, *, min_ms: int | None, max_ms: int | None) -> list[str]:
    return [text for _path, _line, text in call_hits("synthetic.ts", src, name, min_ms=min_ms, max_ms=max_ms)]


def _run_self_test() -> int:
    # 词法边界：注释、字符串与模板字面量里的伪匹配不命中，且后面的真命中不丢。
    masked_src = "\n".join([
        "// await new Promise((r) => setTimeout(r, 700));",
        'const note = "setTimeout(r, 1_300)";',
        "const tpl = `waitFor(p, 500)`;",
        "await new Promise((r) => setTimeout(r, 700));",
    ])
    assert _expect_hits(masked_src, "setTimeout", min_ms=100, max_ms=None) == [
        "await new Promise((r) => setTimeout(r, 700));",
    ], "comment/string/template masks must hide fake hits but keep real ones"

    # 下划线数字与 100ms 边界。
    assert _expect_hits("setTimeout(r, 1_300);", "setTimeout", min_ms=100, max_ms=None)
    assert _expect_hits("setTimeout(r, 100);", "setTimeout", min_ms=100, max_ms=None)
    assert not _expect_hits("setTimeout(r, 99);", "setTimeout", min_ms=100, max_ms=None)
    assert not _expect_hits("setTimeout(r, 0);", "setTimeout", min_ms=100, max_ms=None)

    # 变量延迟（withTimeout 辅助、替身方法定义）不命中。
    assert not _expect_hits(
        "timer = setTimeout(() => reject(new Error(message)), timeoutMs);",
        "setTimeout", min_ms=100, max_ms=None,
    )
    assert not _expect_hits(
        "public setTimeout(handler: () => void, delayMs: number): ReturnType<typeof setTimeout> {",
        "setTimeout", min_ms=100, max_ms=None,
    )

    # window.setTimeout 与跨行调用命中。
    assert _expect_hits("window.setTimeout(() => {}, 120_000);", "setTimeout", min_ms=100, max_ms=None)
    multiline = "window.setTimeout(\n  () => {},\n  120_000,\n);"
    assert _expect_hits(multiline, "setTimeout", min_ms=100, max_ms=None)

    # waitFor：亚秒命中，1_000 及以上、单参、非数字第二参不命中。
    assert _expect_hits("await waitFor(() => expiredCount === 1, 500);", "waitFor", min_ms=None, max_ms=999)
    assert _expect_hits("await waitFor(p, 999);", "waitFor", min_ms=None, max_ms=999)
    assert not _expect_hits("await waitFor(p, 1_000);", "waitFor", min_ms=None, max_ms=999)
    assert not _expect_hits("await waitFor(p, 2_000);", "waitFor", min_ms=None, max_ms=999)
    assert not _expect_hits("await waitFor(p);", "waitFor", min_ms=None, max_ms=999)
    assert not _expect_hits('await waitFor(p, "message");', "waitFor", min_ms=None, max_ms=999)
    # waitFor 的函数签名默认值不是调用点。
    assert not _expect_hits(
        "async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {}",
        "waitFor", min_ms=None, max_ms=999,
    )

    # 棘轮：超出上限报错、低于上限要求下调、归零要求移除条目。
    hits: list[Hit] = [("f.ts", 1, "setTimeout(r, 700);"), ("f.ts", 2, "setTimeout(r, 700);")]
    unexpected, stale = classify(hits, {}, {"f.ts": 1})
    assert len(unexpected) == 2 and "超出历史上限 1" in unexpected[0], unexpected
    assert not stale
    unexpected, stale = classify(hits[:1], {}, {"f.ts": 2})
    assert not unexpected
    assert len(stale) == 1 and "实际剩余 1 处（历史上限 2）" in stale[0], stale
    unexpected, stale = classify([], {}, {"f.ts": 1})
    assert not unexpected and len(stale) == 1 and "实际剩余 0 处（历史上限 1）" in stale[0], stale
    unexpected, stale = classify([], {}, {"f.ts": 0})
    assert not unexpected and any("历史上限必须 > 0" in item for item in stale), stale

    # 允许项：可消费一次，条目消失后报过期。
    allow: Allowlist = {"f.ts": {"setTimeout(r, 700);": (1, "reason")}}
    unexpected, stale = classify([("f.ts", 7, "setTimeout(r, 700);")], allow, None)
    assert not unexpected and not stale
    unexpected, stale = classify([], allow, None)
    assert not unexpected and len(stale) == 1 and "允许了 1 处不存在的" in stale[0], stale

    print("✅ check_windows_test_lints 自测通过")
    return 0


def main() -> None:
    if "--self-test" in sys.argv:
        raise SystemExit(_run_self_test())
    sleep_hits = scan_tree(blind_sleeps)
    waitfor_hits = scan_tree(short_waitfors)
    if "--report" in sys.argv:
        for path, line_no, text in sleep_hits:
            print(f"sleep {path}:{line_no}: {text}")
        for path, line_no, text in waitfor_hits:
            print(f"waitfor {path}:{line_no}: {text}")
        print(f"sleeps {len(sleep_hits)} waitfors {len(waitfor_hits)}")
        return
    ok = report(
        "测试里没有未说明的裸墙钟长睡眠（setTimeout 数字字面量 >= 100 ms）",
        sleep_hits,
        ALLOWLIST,
        LEGACY_BLIND_SLEEP_CEILING,
    )
    ok = report(
        "测试里没有亚秒级短上限 waitFor（第二参 < 1000 ms）",
        waitfor_hits,
        {},
        LEGACY_SHORT_WAITFOR_CEILING,
    ) and ok
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
