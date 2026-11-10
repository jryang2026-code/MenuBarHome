#!/usr/bin/env python3
"""Three test-harness lints.

1. A fixed-count Task.yield loop in Tests. A loop that exits with break, or whose
   header has where, is a poll of an observable and is left alone.
2. #expect(...allSatisfy(\\. — a key path inside the Swift Testing macro.
3. A bare Task-returning call inside withAnimation. Assigning or discarding the
   task keeps the animation closure's result Void.

Each lint has a self-test. An allowlist entry needs a reason. A listed call that
disappears fails the check, so the reason cannot outlive the code.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent

# Camera retry tests wait after FakePTZClient.waitForStops, which returns when the
# stop method is entered. The controller writes ptzNotice after that method returns.
# It does not publish a counter for "the stop result was applied".
YIELD_ALLOWLIST: dict[str, dict[str, tuple[int, str]]] = {
    "Tests/MenuBarMijiaAppTests/CameraPTZDriverTests.swift": {
        "for _ in 0..<500": (
            5,
            "Each loop follows FakePTZClient.waitForStops. That wait returns when the stop "
            "method is entered, and the controller applies ptzNotice and offersPTZStopRetry "
            "after the method returns. These five tests assert that later state. The controller "
            "does not publish a counter for the applied result.",
        ),
    },
}

EXPECT_ALLOWLIST: dict[str, dict[str, tuple[int, str]]] = {}
ANIMATION_ALLOWLIST: dict[str, dict[str, tuple[int, str]]] = {}

TASK_METHODS = (
    "togglePrimary",
    "rehearseAllOff",
    "turnAllOff",
    "undoTurnAllOff",
    "triggerScene",
    "executeQuickAction",
    "executeSafetyAlertAction",
    "maybeRefreshProactiveSuggestionsInBackground",
)


def code_mask(src: str) -> bytearray:
    code = bytearray(len(src))
    i = 0
    n = len(src)
    while i < n:
        if src.startswith("///", i) or src.startswith("//", i):
            i = src.find("\n", i)
            if i < 0:
                break
            continue
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if src.startswith('"""', i):
            end = src.find('"""', i + 3)
            i = n if end < 0 else end + 3
            continue
        if src[i] == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        code[i] = 1
        i += 1
    return code


def masked(src: str, code: bytearray, start: int, end: int) -> str:
    return "".join(src[i] if code[i] else " " for i in range(start, end))


def collapse(text: str) -> str:
    return " ".join(text.split())


def matching_brace(src: str, code: bytearray, open_index: int) -> int | None:
    depth = 0
    i = open_index
    n = len(src)
    while i < n:
        if not code[i]:
            i += 1
            continue
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def matching_paren(src: str, code: bytearray, open_index: int) -> int | None:
    depth = 0
    i = open_index
    n = len(src)
    while i < n:
        if not code[i]:
            i += 1
            continue
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def line_no(src: str, index: int) -> int:
    return src.count("\n", 0, index) + 1


def yield_loops(path: str, src: str) -> list[tuple[str, int, str]]:
    code = code_mask(src)
    hits: list[tuple[str, int, str]] = []
    i = 0
    n = len(src)
    while i < n:
        if code[i] and src.startswith("for", i) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")):
            after = i + 3
            if after < n and (src[after].isalnum() or src[after] == "_"):
                i += 1
                continue
            brace = None
            j = i
            while j < n:
                if code[j] and src[j] == "{":
                    brace = j
                    break
                j += 1
            if brace is None:
                break
            header = collapse(masked(src, code, i, brace))
            end = matching_brace(src, code, brace)
            if end is None:
                break
            body = masked(src, code, brace, end + 1)
            integer_range = False
            parts = header.split()
            if (
                len(parts) >= 4
                and parts[0] == "for"
                and parts[2] == "in"
                and "where" not in parts
            ):
                bounds = parts[3]
                integer_range = ".." in bounds and bounds.replace(".", "").replace("<", "").replace("_", "").isdigit()
            if integer_range and "Task.yield" in body and "break" not in body.split():
                hits.append((path, line_no(src, i), header))
            i = end + 1
            continue
        i += 1
    return hits


def expect_keypaths(path: str, src: str) -> list[tuple[str, int, str]]:
    code = code_mask(src)
    hits: list[tuple[str, int, str]] = []
    token = "#expect"
    i = 0
    while True:
        found = src.find(token, i)
        if found < 0:
            break
        if not code[found]:
            i = found + 1
            continue
        paren = found + len(token)
        while paren < len(src) and code[paren] and src[paren] in " \t\r\n":
            paren += 1
        if paren >= len(src) or src[paren] != "(":
            i = found + 1
            continue
        end = matching_paren(src, code, paren)
        if end is None:
            break
        chunk = masked(src, code, found, end + 1)
        if "allSatisfy(\\." in chunk:
            hits.append((path, line_no(src, found), "#expect(...allSatisfy(\\.)"))
        i = end + 1
    return hits


def is_name(src: str, code: bytearray, i: int, name: str) -> bool:
    if not src.startswith(name, i) or not code[i]:
        return False
    if i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"):
        return False
    after = i + len(name)
    if after < len(src) and code[after] and (src[after].isalnum() or src[after] == "_"):
        return False
    return True


def animation_tasks(path: str, src: str) -> list[tuple[str, int, str]]:
    code = code_mask(src)
    hits: list[tuple[str, int, str]] = []
    i = 0
    n = len(src)
    while i < n:
        if is_name(src, code, i, "withAnimation"):
            j = i + len("withAnimation")
            while j < n and code[j] and src[j] in " \t\r\n":
                j += 1
            if j < n and src[j] == "(":
                end_paren = matching_paren(src, code, j)
                if end_paren is None:
                    break
                j = end_paren + 1
            while j < n and code[j] and src[j] in " \t\r\n":
                j += 1
            if j < n and src[j] == "{":
                end = matching_brace(src, code, j)
                if end is None:
                    break
                body = masked(src, code, j, end + 1)
                for name in TASK_METHODS:
                    cursor = 0
                    while True:
                        at = body.find(name, cursor)
                        if at < 0:
                            break
                        absolute = j + at
                        if is_name(src, code, absolute, name):
                            call = absolute + len(name)
                            while call < end and code[call] and src[call] in " \t\r\n":
                                call += 1
                            if call < end and src[call] == "(":
                                prefix = body[:at]
                                boundary = max(prefix.rfind("{"), prefix.rfind(";"), prefix.rfind("\n"))
                                statement = prefix[boundary + 1 :]
                                if "=" not in statement and "return" not in statement.split():
                                    hits.append((path, line_no(src, absolute), name + "()"))
                        cursor = at + len(name)
                i = end + 1
                continue
        i += 1
    return hits


def classify(
    hits: list[tuple[str, int, str]],
    allowlist: dict[str, dict[str, tuple[int, str]]],
) -> tuple[list[str], list[str]]:
    remaining = {path: dict(entries) for path, entries in allowlist.items()}
    unexpected: list[str] = []
    for path, line, text in hits:
        allowed = remaining.get(path, {}).get(text)
        if allowed is None:
            unexpected.append(f"{path}:{line}: {text}")
            continue
        count, reason = allowed
        if count <= 0:
            unexpected.append(f"{path}:{line}: {text}")
            continue
        remaining[path][text] = (count - 1, reason)
    stale: list[str] = []
    for path, entries in remaining.items():
        for text, (count, reason) in entries.items():
            if count != 0:
                stale.append(f"{path}: 允许了 {count} 处不存在的 `{text}`（{reason}）")
    return unexpected, stale


def scan_dir(root: Path, suffix: str, finder) -> list[tuple[str, int, str]]:
    hits: list[tuple[str, int, str]] = []
    if not root.is_dir():
        return hits
    for path in sorted(root.rglob("*.swift")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        hits.extend(finder(rel, path.read_text(encoding="utf-8")))
    return hits


def self_test() -> None:
    yield_src = "\n".join(
        [
            "for _ in 0..<50 { await Task.yield() }",
            "for _ in 0..<5000 where ready { await Task.yield() }",
            "for _ in 0..<10 { if done { break }; await Task.yield() }",
            "for attempt in 0..<400 {",
            "    if await condition() { return }",
            "    await Task.yield()",
            "}",
            "let note = \"for _ in 0..<3 { await Task.yield() }\"",
        ]
    )
    yield_hits = [text for _, _, text in yield_loops("fixture.swift", yield_src)]
    if yield_hits != ["for _ in 0..<50", "for attempt in 0..<400"]:
        raise SystemExit(f"self-test yield loops: {yield_hits}")

    expect_src = "\n".join(
        [
            "#expect(items.allSatisfy(\\.isOn))",
            "#expect(items.allSatisfy { $0.isOn })",
            "let ok = items.allSatisfy(\\.isOn)",
            "#expect(flag)",
        ]
    )
    expect_hits = expect_keypaths("fixture.swift", expect_src)
    if len(expect_hits) != 1:
        raise SystemExit(f"self-test allSatisfy: {expect_hits}")

    animation_src = "\n".join(
        [
            "withAnimation(motion) { store.togglePrimary(device) }",
            "withAnimation(motion) { _ = store.togglePrimary(device) }",
            "withAnimation(motion) { store.turnAllOff() }",
            "store.togglePrimary(device)",
            "withAnimation(motion) { return store.rehearseAllOff() }",
            "withAnimation(motion) {",
            "    // store.undoTurnAllOff()",
            "    store.dismiss()",
            "}",
        ]
    )
    animation_hits = [text for _, _, text in animation_tasks("fixture.swift", animation_src)]
    if animation_hits != ["togglePrimary()", "turnAllOff()"]:
        raise SystemExit(f"self-test animation: {animation_hits}")

    sample = [("Tests/MenuBarMijiaAppTests/CameraPTZDriverTests.swift", 1, "for _ in 0..<500")] * 5
    unexpected, stale = classify(sample, YIELD_ALLOWLIST)
    if unexpected or stale:
        raise SystemExit(f"self-test allowlist consume: {unexpected} {stale}")
    unexpected, stale = classify(sample + [("Tests/Other.swift", 1, "for _ in 0..<1")], YIELD_ALLOWLIST)
    if not unexpected:
        raise SystemExit("self-test allowlist should reject a new loop")
    unexpected, stale = classify(sample[:4], YIELD_ALLOWLIST)
    if not stale:
        raise SystemExit("self-test allowlist should reject a missing loop")


def report(title: str, hits: list[tuple[str, int, str]], allowlist) -> bool:
    unexpected, stale = classify(hits, allowlist)
    if unexpected or stale:
        print(f"❌ {title}", file=sys.stderr)
        for item in unexpected:
            print(f"  {item}", file=sys.stderr)
        for item in stale:
            print(f"  过期的允许项：{item}", file=sys.stderr)
        return False
    print(f"✅ {title}（已注明 {len(hits)} 处）。")
    return True


def main() -> None:
    self_test()
    ok = True
    ok = report(
        "测试里没有未说明的固定次数 Task.yield 循环",
        scan_dir(ROOT / "Tests", ".swift", yield_loops),
        YIELD_ALLOWLIST,
    ) and ok
    ok = report(
        "测试里没有 #expect(...allSatisfy(\\.)",
        scan_dir(ROOT / "Tests", ".swift", expect_keypaths),
        EXPECT_ALLOWLIST,
    ) and ok
    ok = report(
        "withAnimation 里没有丢掉返回值的 Task 调用",
        scan_dir(ROOT / "Sources", ".swift", animation_tasks),
        ANIMATION_ALLOWLIST,
    ) and ok
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
