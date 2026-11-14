#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent

COMMENT = 0
CODE = 1
STRING = 2
_CODE_ONLY_TABLE = bytes(1 if b == CODE else 0 for b in range(256))

Hit = tuple[str, int, str]
Allowlist = dict[str, dict[str, tuple[int, str]]]
RatchetCeiling = dict[str, int]


@dataclass(frozen=True)
class LintRule:
    title: str
    scan_subdir: str
    finder: Callable[[str, str], list[Hit]]
    allowlist: Allowlist = field(default_factory=dict)
    ratchet_ceiling: RatchetCeiling = field(default_factory=dict)


YIELD_ALLOWLIST: Allowlist = {
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

SLEEP_LOOP_ALLOWLIST: Allowlist = {
    "Tests/MijiaCoreTests/LGWebOSTLSIntegrationTests.swift": {
        "for attempt in 0..<40": (
            1,
            "Retries real URLSession TCP connection against a freshly spawned child `openssl s_server` "
            "process while its listening socket finishes binding.",
        ),
    },
}

LEGACY_SLEEP_LOOP_CEILING: RatchetCeiling = {
    "Tests/MenuBarMijiaAppTests/MenuBarPanelControllerTests.swift": 5,
    "Tests/MenuBarMijiaAppTests/NotificationPermissionTests.swift": 1,
    "Tests/MenuBarMijiaAppTests/PanelLayoutStoreTests.swift": 1,
    "Tests/MenuBarMijiaAppTests/PreReleaseMacOSUIFixesTests.swift": 1,
    "Tests/MijiaCoreTests/AppURLCommandTests.swift": 1,
    "Tests/MijiaCoreTests/AssistantScheduleTests.swift": 4,
    "Tests/MijiaCoreTests/AuditWave2Tests.swift": 3,
    "Tests/MijiaCoreTests/AutomationExecutionTests.swift": 1,
    "Tests/MijiaCoreTests/BareCategoryCommandStoreTests.swift": 2,
    "Tests/MijiaCoreTests/BathHeaterHoodDeviceTests.swift": 3,
    "Tests/MijiaCoreTests/ControlFailureTests.swift": 1,
    "Tests/MijiaCoreTests/CoverDeviceTests.swift": 4,
    "Tests/MijiaCoreTests/CoverMovingStateTests.swift": 1,
    "Tests/MijiaCoreTests/DeviceReadoutTests.swift": 12,
    "Tests/MijiaCoreTests/DualSourceIntegrationTests.swift": 1,
    "Tests/MijiaCoreTests/EnergyHistoryTests.swift": 1,
    "Tests/MijiaCoreTests/FallbackControlTests.swift": 1,
    "Tests/MijiaCoreTests/HAAddressPolicyTests.swift": 1,
    "Tests/MijiaCoreTests/HabitShareTests.swift": 1,
    "Tests/MijiaCoreTests/LaundryDeviceTests.swift": 1,
    "Tests/MijiaCoreTests/LightGroupFoldTests.swift": 2,
    "Tests/MijiaCoreTests/ManualHabitRecordingTests.swift": 3,
    "Tests/MijiaCoreTests/MenuBarMetricOptionsTests.swift": 1,
    "Tests/MijiaCoreTests/MiCloudPollingTests.swift": 2,
    "Tests/MijiaCoreTests/MiCloudTests.swift": 1,
    "Tests/MijiaCoreTests/MijiaCoreTests.swift": 5,
    "Tests/MijiaCoreTests/MiotCompatibilityTests.swift": 1,
    "Tests/MijiaCoreTests/OnboardingChecklistTests.swift": 1,
    "Tests/MijiaCoreTests/PanelActivityFeedTests.swift": 1,
    "Tests/MijiaCoreTests/PanelHealthTests.swift": 2,
    "Tests/MijiaCoreTests/ProactiveSuggestionRefreshTests.swift": 1,
    "Tests/MijiaCoreTests/ScheduledCommandScopeTests.swift": 1,
    "Tests/MijiaCoreTests/SensorSafetyAlertTests.swift": 3,
    "Tests/MijiaCoreTests/SnapshotObservationTests.swift": 3,
    "Tests/MijiaCoreTests/WaterHeaterDeviceTests.swift": 7,
}

RESUME_SCHEDULER_ALLOWLIST: Allowlist = {}

COVERAGE_SPECS_ALLOWLIST: Allowlist = {
    "Tests/MijiaCoreTests/MiotCoverageBaselineTests.swift": {
        "miot_coverage_specs.json": (
            1,
            "Single cached decode (`cachedSpecsResult`) for MijiaCoreTests; other suites must call "
            "`MiotCoverageBaselineTests.coverageSpecs()` or `coverageSpec(_:)`.",
        ),
    },
    "Tests/MenuBarMijiaAppTests/SnapshotTests.swift": {
        "miot_coverage_specs.json": (
            1,
            "MenuBarMijiaAppTests is a separate SwiftPM test target that cannot import MijiaCoreTests; "
            "`fishTank()` is the single spec-backed UI snapshot fixture in MenuBarMijiaAppTests.",
        ),
    },
}

EXPECT_ALLOWLIST: Allowlist = {}
ANIMATION_ALLOWLIST: Allowlist = {}

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

_CODE_OUTER_RE = re.compile(r'//|/\*|#*"')
_CODE_INTERP_RE = re.compile(r'//|/\*|#*"|[()]')
_BLOCK_COMMENT_RE = re.compile(r"/\*|\*/")
_STRING_PAT_CACHE: dict[tuple[int, bool], re.Pattern[str]] = {}
_INT_FOR_HEADER_RE = re.compile(
    r"^for\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*[A-Za-z_][A-Za-z0-9_.]*)?\s+in\s+\(?\s*([0-9][0-9_]*\s*(?:\.\.<|\.\.\.)\s*[0-9][0-9_]*)\s*\)?(?:\s+(where)\b.*)?$"
)
_TASK_SLEEP_RE = re.compile(r"\bTask\s*\.\s*sleep\b")
_CONTINUOUS_CLOCK_RE = re.compile(r"\bContinuousClock\b(?!\s*\.\s*Instant\b)")
_ASSIGN_RE = re.compile(r"(?<![=!<>])=(?!=)")
_LIVE_SHORTHAND_RE = re.compile(r"(?:\bresumeScheduler\s*=\s*\.live\b|:\s*DebouncedResumeScheduler\s*=\s*\.live\b)")
_STEM_EXT_RE = re.compile(r'"[^"\n]*miot_coverage_specs"\s*\)?\s*\.\s*appendingPathExtension\s*\(\s*"json"\s*\)')


def _scan_swift_string(
    src: str, kind: bytearray, interp_stack: list[tuple[int, int, bool]], start_mark: int, pos: int, hashes: int, multiline: bool
) -> int:
    n = len(src)
    close_delim = ('"""' if multiline else '"') + ("#" * hashes)
    esc_prefix = "\\" + ("#" * hashes)
    pat = _STRING_PAT_CACHE.get((hashes, multiline))
    if pat is None:
        pat = re.compile(re.escape(esc_prefix) + r"|" + re.escape(close_delim))
        _STRING_PAT_CACHE[(hashes, multiline)] = pat
    while pos < n:
        m = pat.search(src, pos)
        if m is None:
            kind[start_mark:n] = b"\x02" * (n - start_mark)
            return n
        hit = m.start()
        if src.startswith(esc_prefix, hit):
            after_esc = hit + len(esc_prefix)
            if after_esc < n and src[after_esc] == "(":
                end_str = after_esc + 1
                kind[start_mark:end_str] = b"\x02" * (end_str - start_mark)
                interp_stack.append((1, hashes, multiline))
                return end_str
            pos = min(after_esc + 1, n)
            continue
        end_delim = hit + len(close_delim)
        kind[start_mark:end_delim] = b"\x02" * (end_delim - start_mark)
        return end_delim
    kind[start_mark:n] = b"\x02" * (n - start_mark)
    return n


def _scan_block_comment(src: str, kind: bytearray, start: int) -> int:
    depth, i, n = 1, start + 2, len(src)
    while i < n and depth > 0:
        bm = _BLOCK_COMMENT_RE.search(src, i)
        if bm is None:
            i = n
            break
        depth += 1 if bm.group(0) == "/*" else -1
        i = bm.end()
    kind[start:i] = b"\x00" * (i - start)
    return i


def lex_swift(src: str) -> bytearray:
    n, i = len(src), 0
    kind = bytearray(b"\x01" * n)
    interp_stack: list[tuple[int, int, bool]] = []
    while i < n:
        m = (_CODE_INTERP_RE if interp_stack else _CODE_OUTER_RE).search(src, i)
        if m is None:
            break
        i, tok = m.start(), m.group(0)
        if tok == "//":
            end = src.find("\n", i + 2)
            stop = n if end < 0 else end
            kind[i:stop] = b"\x00" * (stop - i)
            i = n if end < 0 else end + 1
        elif tok == "/*":
            i = _scan_block_comment(src, kind, i)
        elif tok.endswith('"'):
            hashes = len(tok) - 1
            q_pos = i + hashes
            multiline = src.startswith(('"""\n', '"""\r\n'), q_pos)
            i = _scan_swift_string(src, kind, interp_stack, i, q_pos + (3 if multiline else 1), hashes, multiline)
        elif tok == "(":
            depth, hashes, multiline = interp_stack[-1]
            interp_stack[-1] = (depth + 1, hashes, multiline)
            i += 1
        else:
            depth, hashes, multiline = interp_stack[-1]
            if depth == 1:
                interp_stack.pop()
                i = _scan_swift_string(src, kind, interp_stack, i, i + 1, hashes, multiline)
            else:
                interp_stack[-1] = (depth - 1, hashes, multiline)
                i += 1
    return kind


def code_mask(src: str) -> bytearray:
    return lex_swift(src).translate(_CODE_ONLY_TABLE)


def masked(src: str, code: bytearray, start: int, end: int) -> str:
    return "".join(src[i] if code[i] else " " for i in range(start, end))


def collapse(text: str) -> str:
    return " ".join(text.split())


def _matching_delim(src: str, code: bytearray, open_index: int, open_ch: str, close_ch: str) -> int | None:
    depth, i, n = 0, open_index, len(src)
    while i < n:
        if code[i]:
            if src[i] == open_ch:
                depth += 1
            elif src[i] == close_ch:
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return None


def matching_brace(src: str, code: bytearray, open_index: int) -> int | None:
    return _matching_delim(src, code, open_index, "{", "}")


def matching_paren(src: str, code: bytearray, open_index: int) -> int | None:
    return _matching_delim(src, code, open_index, "(", ")")


def line_no(src: str, index: int) -> int:
    return src.count("\n", 0, index) + 1


def _skip_ws_comments(src: str, code: bytearray, j: int, stop: int | None = None, *, include_newlines: bool = True) -> int:
    limit = len(src) if stop is None else stop
    ws = " \t\r\n" if include_newlines else " \t"
    while j < limit and (not code[j] or src[j] in ws):
        j += 1
    return j


def _is_header_closure_continuation(src: str, code: bytearray, close_brace: int, limit: int) -> bool:
    nxt = _skip_ws_comments(src, code, close_brace + 1, limit)
    if nxt >= limit or not code[nxt]:
        return False
    if src[nxt] in ".[?!{,":
        return True
    if any(is_name(src, code, nxt, kw) for kw in ("where", "as", "is")):
        return True
    return src.startswith(("&&", "||", "==", "!=", "<=", ">="), nxt)


def _find_header_brace(src: str, code: bytearray, start: int, limit: int) -> int | None:
    paren_depth, j = 0, start
    while j < limit:
        if code[j]:
            ch = src[j]
            if ch == "(":
                paren_depth += 1
            elif ch == ")":
                paren_depth -= 1
                if paren_depth < 0:
                    return None
            elif ch == ";" and paren_depth == 0:
                return None
            elif ch == "{" and paren_depth == 0:
                close = matching_brace(src, code, j)
                if close is not None and _is_header_closure_continuation(src, code, close, limit):
                    j = close + 1
                    continue
                return j
        j += 1
    return None


def _blank_span(chars: list[str], base: int, start: int, end: int) -> None:
    for idx in range(start, end):
        if chars[idx - base] != "\n":
            chars[idx - base] = " "


def _blank_switch_breaks(src: str, code: bytearray, chars: list[str], base: int, brace: int, end: int) -> None:
    k = brace
    while k < end:
        if is_name(src, code, k, "break"):
            _blank_span(chars, base, k, k + 5)
            k += 5
        else:
            k += 1


def _own_loop_body(src: str, code: bytearray, brace: int, end: int, *, blank_nested_int_for: bool, blank_inner_breaks: bool) -> str:
    chars = list(masked(src, code, brace, end + 1))
    k = brace + 1
    while k < end:
        blanked = False
        for kw in ("for", "while", "repeat", "switch"):
            if not is_name(src, code, k, kw):
                continue
            inner_brace = _find_header_brace(src, code, k + len(kw), end)
            inner_end = matching_brace(src, code, inner_brace) if inner_brace is not None else None
            if inner_brace is not None and inner_end is not None:
                stop = min(inner_end + 1, end + 1)
                if kw == "for" and blank_nested_int_for and _INT_FOR_HEADER_RE.match(collapse(masked(src, code, k, inner_brace))):
                    _blank_span(chars, brace, inner_brace, stop)
                    k, blanked = inner_end + 1, True
                elif blank_inner_breaks:
                    _blank_switch_breaks(src, code, chars, brace, inner_brace, stop)
                    k, blanked = inner_brace + 1, True
            break
        if not blanked:
            k += 1
    return "".join(chars)


def _int_range_for_loops(src: str, code: bytearray) -> list[tuple[int, str, bool, int, int]]:
    loops: list[tuple[int, str, bool, int, int]] = []
    n, cursor = len(src), 0
    while (i := src.find("for", cursor)) >= 0:
        cursor = i + 3
        if not is_name(src, code, i, "for"):
            continue
        brace = _find_header_brace(src, code, cursor, n)
        if brace is None or ".." not in src[i:brace]:
            continue
        hm = _INT_FOR_HEADER_RE.match(header := collapse(masked(src, code, i, brace)))
        if hm is None:
            continue
        end = matching_brace(src, code, brace)
        if end is None:
            break
        loops.append((line_no(src, i), header, hm.group(3) is not None, brace, end))
        cursor = brace + 1
    return loops


def yield_loops(path: str, src: str) -> list[Hit]:
    if "yield" not in src or ".." not in src:
        return []
    code = code_mask(src)
    hits: list[Hit] = []
    for line, header, has_where, brace, end in _int_range_for_loops(src, code):
        if has_where or "yield" not in src[brace : end + 1]:
            continue
        own_body = _own_loop_body(src, code, brace, end, blank_nested_int_for=True, blank_inner_breaks=True)
        if "Task.yield" in own_body and "break" not in own_body.split():
            hits.append((path, line, header))
    return hits


def sleep_loops(path: str, src: str) -> list[Hit]:
    if "sleep" not in src or ".." not in src:
        return []
    code = code_mask(src)
    hits: list[Hit] = []
    for line, header, _, brace, end in _int_range_for_loops(src, code):
        if "sleep" not in src[brace : end + 1]:
            continue
        own_body = _own_loop_body(src, code, brace, end, blank_nested_int_for=True, blank_inner_breaks=False)
        if _TASK_SLEEP_RE.search(own_body):
            hits.append((path, line, header))
    return hits


def _has_top_level_label(src: str, code: bytearray, open_paren: int, close_paren: int, label: str) -> bool:
    chars = list(masked(src, code, open_paren + 1, close_paren))
    k = open_paren + 1
    while k < close_paren:
        if code[k] and src[k] in "({":
            end = matching_paren(src, code, k) if src[k] == "(" else matching_brace(src, code, k)
            if end is not None:
                _blank_span(chars, open_paren + 1, k, min(end + 1, close_paren))
                k = end + 1
                continue
        k += 1
    return re.search(rf"(?:^|,)\s*{label}\s*:", "".join(chars)) is not None


def _is_type_brace_context(src: str, code: bytearray, tok_start: int) -> bool:
    j = tok_start - 1
    while j >= 0 and (not code[j] or src[j] in " \t\r\n"):
        j -= 1
    if j < 0:
        return False
    if src[j] == ":" or (j >= 1 and src[j - 1 : j + 1] == "->"):
        return True
    end = j + 1
    while j >= 0 and code[j] and (src[j].isalnum() or src[j] == "_"):
        j -= 1
    return src[j + 1 : end] in {"extension", "struct", "class", "protocol", "enum", "typealias", "as", "is"}


def _inspect_scheduler_ctor(src: str, code: bytearray, j: int, line: int, path: str) -> tuple[Hit | None, int]:
    n = len(src)
    if src[j] == "(":
        end_paren = matching_paren(src, code, j)
        if end_paren is None:
            return None, n
        has_now = _has_top_level_label(src, code, j, end_paren, "now")
        after = _skip_ws_comments(src, code, end_paren + 1, n)
        call_end = (matching_brace(src, code, after) or end_paren) if after < n and code[after] and src[after] == "{" else end_paren
    else:
        end_brace = matching_brace(src, code, j)
        if end_brace is None:
            return None, n
        has_now, call_end = False, end_brace
    call_code = masked(src, code, j, call_end + 1)
    if _CONTINUOUS_CLOCK_RE.search(call_code):
        return (path, line, "DebouncedResumeScheduler(...ContinuousClock...)"), call_end + 1
    if not has_now:
        return (path, line, "DebouncedResumeScheduler(missing now:)"), call_end + 1
    return None, call_end + 1


def _scan_live_shorthands(path: str, src: str, code: bytearray, hits: list[Hit]) -> None:
    masked_src = masked(src, code, 0, len(src))
    for m in _LIVE_SHORTHAND_RE.finditer(masked_src):
        hits.append((path, line_no(src, m.start()), "DebouncedResumeScheduler.live"))


def live_resume_schedulers(path: str, src: str) -> list[Hit]:
    token = "DebouncedResumeScheduler"
    if token not in src and "resumeScheduler" not in src:
        return []
    code = code_mask(src)
    hits: list[Hit] = []
    _scan_live_shorthands(path, src, code, hits)
    n, cursor = len(src), 0
    while (i := src.find(token, cursor)) >= 0:
        cursor = i + len(token)
        if not is_name(src, code, i, token):
            continue
        j = _skip_ws_comments(src, code, cursor, n)
        if j < n and code[j] and src[j] == ".":
            k = _skip_ws_comments(src, code, j + 1, n)
            if is_name(src, code, k, "live"):
                hits.append((path, line_no(src, i), "DebouncedResumeScheduler.live"))
                cursor = k + 4
                continue
            if not is_name(src, code, k, "init"):
                continue
            j = _skip_ws_comments(src, code, k + 4, n)
        if j >= n or not code[j] or src[j] not in "({" or (src[j] == "{" and _is_type_brace_context(src, code, i)):
            continue
        hit, cursor = _inspect_scheduler_ctor(src, code, j, line_no(src, i), path)
        if hit is not None:
            hits.append(hit)
    hits.sort(key=lambda h: (h[1], h[2]))
    return hits


def _inside_test_attr_args(src: str, code: bytearray, pos: int) -> bool:
    depth, j = 0, pos - 1
    while j >= 0:
        if code[j]:
            if src[j] == ")":
                depth += 1
            elif src[j] == "(":
                if depth == 0:
                    return j >= 5 and code[j - 5 : j] == b"\x01\x01\x01\x01\x01" and src[j - 5 : j] == "@Test"
                depth -= 1
            elif src[j] in "{};" and depth == 0:
                return False
        j -= 1
    return False


def coverage_spec_loads(path: str, src: str) -> list[Hit]:
    if "miot_coverage_specs" not in src:
        return []
    kind = lex_swift(src)
    code = kind.translate(_CODE_ONLY_TABLE)
    hits: list[Hit] = []
    token, i = "miot_coverage_specs.json", 0
    while (found := src.find(token, i)) >= 0:
        if all(kind[k] == STRING for k in range(found, found + len(token))) and not _inside_test_attr_args(src, code, found):
            hits.append((path, line_no(src, found), token))
        i = found + len(token)
    for m in _STEM_EXT_RE.finditer(src):
        if kind[m.start()] == STRING and not _inside_test_attr_args(src, code, m.start()):
            hits.append((path, line_no(src, m.start()), token))
    hits.sort(key=lambda h: (h[1], h[2]))
    return hits


def expect_keypaths(path: str, src: str) -> list[Hit]:
    if "allSatisfy(\\." not in src:
        return []
    code = code_mask(src)
    hits: list[Hit] = []
    token, i = "#expect", 0
    while (found := src.find(token, i)) >= 0:
        if not code[found]:
            i = found + 1
            continue
        paren = _skip_ws_comments(src, code, found + len(token), len(src))
        if paren >= len(src) or src[paren] != "(":
            i = found + 1
            continue
        end = matching_paren(src, code, paren)
        if end is None:
            break
        if "allSatisfy(\\." in masked(src, code, found, end + 1):
            hits.append((path, line_no(src, found), "#expect(...allSatisfy(\\.)"))
        i = end + 1
    return hits


def is_name(src: str, code: bytearray, i: int, name: str) -> bool:
    if not src.startswith(name, i) or not code[i]:
        return False
    if i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"):
        return False
    after = i + len(name)
    return not (after < len(src) and code[after] and (src[after].isalnum() or src[after] == "_"))


def _scan_with_animation_body(path: str, src: str, code: bytearray, brace: int, end: int, hits: list[Hit]) -> None:
    body = masked(src, code, brace, end + 1)
    for name in TASK_METHODS:
        cursor = 0
        while (at := body.find(name, cursor)) >= 0:
            absolute = brace + at
            if is_name(src, code, absolute, name):
                call = _skip_ws_comments(src, code, absolute + len(name), end)
                if call < end and src[call] == "(":
                    prefix = body[:at]
                    boundary = max(prefix.rfind("{"), prefix.rfind(";"), prefix.rfind("\n"))
                    statement = prefix[boundary + 1 :]
                    if not _ASSIGN_RE.search(statement) and "return" not in statement.split():
                        hits.append((path, line_no(src, absolute), name + "()"))
            cursor = at + len(name)


def animation_tasks(path: str, src: str) -> list[Hit]:
    if "withAnimation" not in src or not any(name in src for name in TASK_METHODS):
        return []
    code = code_mask(src)
    hits: list[Hit] = []
    i, n = 0, len(src)
    while i < n:
        if not is_name(src, code, i, "withAnimation"):
            i += 1
            continue
        j = _skip_ws_comments(src, code, i + len("withAnimation"), n)
        if j < n and src[j] == "(":
            end_paren = matching_paren(src, code, j)
            if end_paren is None:
                break
            j = _skip_ws_comments(src, code, end_paren + 1, n)
        if j < n and src[j] == "{":
            end = matching_brace(src, code, j)
            if end is None:
                break
            _scan_with_animation_body(path, src, code, j, end, hits)
            i = end + 1
            continue
        i += 1
    return hits


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
    stale = [
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
            unexpected.extend(f"{path}:{line}: {text}（文件共 {actual} 处，超出历史上限 {ceiling}）" for line, text in file_hits)
        elif actual < ceiling:
            stale.append(f"{path}: 实际剩余 {actual} 处（历史上限 {ceiling}），请同步下调或移除 LEGACY_SLEEP_LOOP_CEILING 条目")
    return unexpected, stale


def evaluate_rule(rule: LintRule, hits: list[Hit]) -> tuple[list[str], list[str]]:
    return classify(hits, rule.allowlist, rule.ratchet_ceiling)


RULES: tuple[LintRule, ...] = (
    LintRule("测试里没有未说明的固定次数 Task.yield 循环", "Tests", yield_loops, YIELD_ALLOWLIST),
    LintRule("测试里没有未说明的固定次数 Task.sleep 循环", "Tests", sleep_loops, SLEEP_LOOP_ALLOWLIST, LEGACY_SLEEP_LOOP_CEILING),
    LintRule("测试里没有使用真时钟 ContinuousClock 的 DebouncedResumeScheduler", "Tests", live_resume_schedulers, RESUME_SCHEDULER_ALLOWLIST),
    LintRule("测试里没有绕过缓存直接加载 miot_coverage_specs.json", "Tests", coverage_spec_loads, COVERAGE_SPECS_ALLOWLIST),
    LintRule("测试里没有 #expect(...allSatisfy(\\.)", "Tests", expect_keypaths, EXPECT_ALLOWLIST),
    LintRule("withAnimation 里没有丢掉返回值的 Task 调用", "Sources", animation_tasks, ANIMATION_ALLOWLIST),
)


def scan_dir(root: Path, suffix: str, finder: Callable[[str, str], list[Hit]]) -> list[Hit]:
    if not root.is_dir():
        return []
    return [
        hit
        for p in sorted(root.rglob(f"*{suffix}"))
        if p.is_file()
        for hit in finder(p.relative_to(ROOT).as_posix(), p.read_text(encoding="utf-8"))
    ]


def _self_test_lexer() -> None:
    lex_src = "\n".join(
        [
            'let q = #"""#',
            'let msg = "prefix \\(fn("inner \\(1 + 2)")) suffix"',
            '/* outer /* nested "miot_coverage_specs.json" */ still comment */',
            'let raw = #"raw "quote" \\#(call("arg")) tail"#',
            'let multi = #"""\n    line "one"\n    """#',
            '// line comment with "miot_coverage_specs.json" and for _ in 0..<5 { await Task.sleep(for: .seconds(1)) }',
            "for _ in 0..<4 { await Task.yield() }",
        ]
    )
    k = lex_swift(lex_src)
    assert k[lex_src.index("prefix")] == STRING and k[lex_src.index("fn(")] == CODE
    assert k[lex_src.index("inner")] == STRING and k[lex_src.index("1 + 2")] == CODE
    assert k[lex_src.index("still comment")] == COMMENT and k[lex_src.index("call(")] == CODE
    assert [t for _, _, t in yield_loops("lex.swift", lex_src)] == ["for _ in 0..<4"]


def _self_test_loops() -> None:
    yield_src = "\n".join(
        [
            "for _ in 0..<50 { await Task.yield() }",
            "for _ in 0..<5000 where ready { await Task.yield() }",
            "for _ in 0..<10 { if done { break }; await Task.yield() }",
            "for _ in 0..<40 {\n  for x in xs.filter { $0.ok } { if x.done { break } }\n  await Task.yield()\n}",
            "for _ in 0..<30 { switch st { case .a: await Task.yield() default: break } }",
        ]
    )
    assert [t for _, _, t in yield_loops("f.swift", yield_src)] == ["for _ in 0..<50", "for _ in 0..<40", "for _ in 0..<30"]
    sleep_src = "\n".join(
        [
            "for i: Int in 0..<10 { try? await Task.sleep(for: .milliseconds(1)) }",
            "for _ in 0..<20 where xs.contains { $0.ok } { try await Task.sleep(for: .milliseconds(5)) }",
            "for outer in 0..<6 {\n  for inner in 0..<7 { try await Task.sleep(for: .milliseconds(1)) }\n}",
            "for outer in 0..<8 {\n  for x in xs.filter { $0.ok } { try await Task.sleep(for: .milliseconds(1)) }\n}",
            "// for _ in 0..<99 { try await Task.sleep(for: .milliseconds(1)) }",
        ]
    )
    assert [t for _, _, t in sleep_loops("f.swift", sleep_src)] == [
        "for i: Int in 0..<10",
        "for _ in 0..<20 where xs.contains { $0.ok }",
        "for inner in 0..<7",
        "for outer in 0..<8",
    ]


def _self_test_scheduler() -> None:
    scheduler_src = "\n".join(
        [
            "let a = DebouncedResumeScheduler.live",
            "store.resumeScheduler = .live",
            "let b: DebouncedResumeScheduler = .live",
            "let c = DebouncedResumeScheduler()",
            "let d = DebouncedResumeScheduler.init()",
            "let e = DebouncedResumeScheduler(sleep: { _ in })",
            "let f = DebouncedResumeScheduler { _ in }",
            "let g = DebouncedResumeScheduler(now: { ContinuousClock.now }, sleep: { _ in })",
            "let h = DebouncedResumeScheduler(now: { clock.now })\n{ _ in _ = ContinuousClock.now }",
            "let ok = DebouncedResumeScheduler(now: { () -> ContinuousClock.Instant in clock.now }, sleep: { _ in })",
            "func make() -> DebouncedResumeScheduler { DebouncedResumeScheduler(now: { clock.now }, sleep: { _ in }) }",
            "extension DebouncedResumeScheduler { var custom: DebouncedResumeScheduler { DebouncedResumeScheduler(now: { clock.now }, sleep: { _ in }) } }",
        ]
    )
    assert [(l, t) for _, l, t in live_resume_schedulers("f.swift", scheduler_src)] == [
        (1, "DebouncedResumeScheduler.live"),
        (2, "DebouncedResumeScheduler.live"),
        (3, "DebouncedResumeScheduler.live"),
        (4, "DebouncedResumeScheduler(missing now:)"),
        (5, "DebouncedResumeScheduler(missing now:)"),
        (6, "DebouncedResumeScheduler(missing now:)"),
        (7, "DebouncedResumeScheduler(missing now:)"),
        (8, "DebouncedResumeScheduler(...ContinuousClock...)"),
        (9, "DebouncedResumeScheduler(...ContinuousClock...)"),
    ]


def _self_test_cov_anim_ratchet() -> None:
    cov_src = (
        '@Test("Uses cached miot_coverage_specs.json")\n'
        'func t() { _ = dir.appendingPathComponent("miot_coverage_specs").appendingPathExtension("json") }\n'
        'let p = "Tests/Fixtures/miot_coverage_specs.json"\n'
    )
    assert [(l, t) for _, l, t in coverage_spec_loads("f.swift", cov_src)] == [(2, "miot_coverage_specs.json"), (3, "miot_coverage_specs.json")]
    anim_src = (
        "withAnimation(m) /* c */ { store.togglePrimary(d) }\n"
        "withAnimation(m) { (a == b ? s1 : s2).turnAllOff() }\n"
        "withAnimation(m) { _ = store.togglePrimary(d); return store.rehearseAllOff() }\n"
    )
    assert [t for _, _, t in animation_tasks("f.swift", anim_src)] == ["togglePrimary()", "turnAllOff()"]
    ratchet_rule = LintRule("sleep ratchet", "Tests", sleep_loops, SLEEP_LOOP_ALLOWLIST, {"Tests/F.swift": 2})
    hits = [("Tests/MijiaCoreTests/LGWebOSTLSIntegrationTests.swift", 178, "for attempt in 0..<40"), ("Tests/F.swift", 1, "for _ in 0..<2"), ("Tests/F.swift", 2, "for _ in 0..<3")]
    assert evaluate_rule(ratchet_rule, hits) == ([], [])
    assert classify(hits, SLEEP_LOOP_ALLOWLIST, {"Tests/F.swift": 1})[0]
    assert classify(hits, SLEEP_LOOP_ALLOWLIST, {"Tests/F.swift": 3})[1]
    assert classify(hits[:1], SLEEP_LOOP_ALLOWLIST, {"Tests/Zero.swift": 0})[1]


def self_test() -> None:
    _self_test_lexer()
    _self_test_loops()
    _self_test_scheduler()
    _self_test_cov_anim_ratchet()
    assert len(expect_keypaths("f.swift", "#expect(items.allSatisfy(\\.isOn))\n#expect(items.allSatisfy { $0.isOn })\n")) == 1
    sample = [("Tests/MenuBarMijiaAppTests/CameraPTZDriverTests.swift", 1, "for _ in 0..<500")] * 5
    assert classify(sample, YIELD_ALLOWLIST) == ([], [])
    assert classify(sample + [("Tests/Other.swift", 1, "for _ in 0..<1")], YIELD_ALLOWLIST)[0]
    assert classify(sample[:4], YIELD_ALLOWLIST)[1]


def report(title: str, hits: list[Hit], allowlist: Allowlist, ratchet_ceiling: RatchetCeiling | None = None) -> bool:
    unexpected, stale = classify(hits, allowlist, ratchet_ceiling)
    if unexpected or stale:
        print(f"❌ {title}", file=sys.stderr)
        for item in unexpected + [f"过期的允许项：{s}" for s in stale]:
            print(f"  {item}", file=sys.stderr)
        return False
    print(f"✅ {title}（已注明 {len(hits)} 处）。")
    return True


def main(argv: list[str] | None = None) -> None:
    args = sys.argv[1:] if argv is None else argv
    if "--self-test" in args:
        self_test()
        print("✅ check_swift_harness_lints.py self-test 通过。")
        return
    ok = True
    for rule in RULES:
        ok = report(rule.title, scan_dir(ROOT / rule.scan_subdir, ".swift", rule.finder), rule.allowlist, rule.ratchet_ceiling) and ok
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
