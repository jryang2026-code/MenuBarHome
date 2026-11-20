#!/usr/bin/env bash
# `swift test` with a stall watchdog for the macOS CI runner.
#
# A deadlocked test can suspend a checked continuation forever: the suite time limit records an
# issue but cannot resume the continuation, so the job sits silent until its 45-minute timeout.
# After SWIFT_TEST_STALL_SECONDS without new output this script samples every swiftpm-testing
# process (Swift stacks) into the job log. It fails the step only when that log has no passing
# summary. A suite that already printed one and then hung at exit is a pass.
#
# Success is decided by Swift Testing's own summary line, never by the exit code or by the
# watchdog. A passing run can fail to exit on macos-26 (SwiftPM #8394), and `script` does not
# reliably forward the child status. A run with no summary line is a failure.
#
# A crash additionally dumps filtered fields from the macOS `ReportCrash` `.ips` report for the
# crashing test process (exception type, faulting thread, and `atos`-symbolized stack frames): the
# runner is destroyed with the job, so this metadata is only readable inside the step that saw it.
#
# A failing run is rerun once, filtered to just the failing cases, to separate a flake from a real
# break inside one job. The parse and verdict rules live in `scripts/lib/swift_test_retry.sh`, which
# the Linux runner (`scripts/linux-check/run.sh`) sources too: one implementation, both platforms.
# The rerun needs the case's `Suite.func`, which the log does not print: `--filter` matches the test
# id, never the display name, so the function is read from the source file named in the recorded
# location. A rerun that passes turns the job green with `::warning::flaky tests passed on retry`
# plus a `$GITHUB_STEP_SUMMARY` table; a crash, a stall, more than five failing cases, or a rerun
# that fails again keeps the failure. CI only (`CI=true`); `CI_RETRY_FAILED=0/1` overrides either
# way.
#
# Usage:
#   bash scripts/ci_swift_test.sh [swift test arguments...]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Prints filtered crash metadata from newest macOS `.ips` reports written for this test run's
# process (`swiftpm-testing-helper` / `xctest`) matching the captured PID / parent-PID tree.
#
# Diagnosis is bounded by a single total deadline and must never change the step verdict: every
# command is best-effort and every failure prints a warning instead of a non-zero status.
dump_macos_crash_reports() {
    local min_epoch="${1:-0}"
    local run_pids="${2:-}"
    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    echo "=== macOS crash reports (ReportCrash)"
    CRASH_REPORT_MIN_EPOCH="$min_epoch" \
    CRASH_REPORT_RUN_PIDS="${CRASH_REPORT_RUN_PIDS:-$run_pids}" \
    CRASH_REPORT_SEARCH_DIRS="${CRASH_REPORT_SEARCH_DIRS:-$(printf '%s\n%s\n' "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")}" \
        python3 - <<'PY' || echo "::warning::could not read the macOS crash reports (see the log above)"
import glob
import json
import os
import re
import subprocess
import time

# Single end-to-end budget across report polling and `atos` symbolization.
TOTAL_BUDGET_SECONDS = max(1.0, float(os.environ.get("CRASH_REPORT_BUDGET_SECONDS", "90")))
# ReportCrash flushes the `.ips` asynchronously after the abort and a loaded runner can take a while,
# so poll instead of racing a fixed sleep.
REPORT_WAIT_SECONDS = min(45.0, TOTAL_BUDGET_SECONDS)
POLL_SECONDS = 2.0
ALLOWED_PROC_NAMES = ("swiftpm-testing-helper", "xctest")
NAME_PATTERNS = (
    "swiftpm-testing-helper-*",
    "swiftpm-testing-helper.*",
    "xctest-*",
    "xctest.*",
)
MAX_REPORTS = 2
ATOS_PER_CALL_CAP_SECONDS = 15.0
# Only our own modules are worth an `atos` call: system frames keep the symbols ReportCrash recorded.
SYMBOLIZE_IMAGES = ("MenuBarMijiaPackageTests", "MijiaCore", "MenuBarMijiaApp")
ABS_SOURCE_LOC_RE = re.compile(r"\((?:/[^():]+)+/([^/():]+)(:\d+)?\)")

search_dirs = [line for line in os.environ.get("CRASH_REPORT_SEARCH_DIRS", "").splitlines() if line]
try:
    min_epoch = float(os.environ.get("CRASH_REPORT_MIN_EPOCH", "0"))
except ValueError:
    min_epoch = 0.0

run_pids = set()
for token in re.split(r"[\s,]+", os.environ.get("CRASH_REPORT_RUN_PIDS", "").strip()):
    if not token:
        continue
    try:
        parsed = int(token)
    except ValueError:
        continue
    if parsed > 0:
        run_pids.add(parsed)

total_deadline = time.monotonic() + TOTAL_BUDGET_SECONDS


def remaining_budget():
    return max(0.0, total_deadline - time.monotonic())


def to_int(value):
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        return None


def to_hex(value):
    number = to_int(value)
    return "0x%x" % number if number is not None else str(value)


def parse_ips(path):
    try:
        with open(path, "r", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    # An `.ips` is two JSON documents: a one-line header, then the report body.
    try:
        header = json.loads(lines[0]) if lines else {}
        body = json.loads("\n".join(lines[1:])) if len(lines) > 1 else {}
    except ValueError:
        return None
    if not isinstance(header, dict) or not isinstance(body, dict):
        return None
    return header, body


def matches_run_report(header, body):
    proc_name = str(header.get("app_name") or body.get("procName") or "")
    if proc_name not in ALLOWED_PROC_NAMES:
        return False
    if not run_pids:
        return True
    pid = to_int(body.get("pid"))
    if pid is None:
        pid = to_int(header.get("pid"))
    parent_pid = to_int(body.get("parentPid"))
    if parent_pid is None:
        parent_pid = to_int(header.get("parentPid"))
    return (pid in run_pids) or (parent_pid in run_pids)


def recent_reports():
    now = time.time()
    cutoff = min_epoch if min_epoch > 0 else (now - 600.0)
    found = []
    seen = set()
    for directory in search_dirs:
        for pattern in NAME_PATTERNS:
            for path in glob.glob(os.path.join(directory, pattern + ".ips")):
                if path in seen:
                    continue
                seen.add(path)
                try:
                    modified = os.path.getmtime(path)
                except OSError:
                    continue
                if modified < cutoff:
                    continue
                parsed = parse_ips(path)
                if parsed is None:
                    continue
                header, body = parsed
                if matches_run_report(header, body):
                    found.append((modified, path, header, body))
    found.sort(key=lambda item: item[0], reverse=True)
    return found


poll_deadline = min(total_deadline, time.monotonic() + REPORT_WAIT_SECONDS)
candidates = recent_reports()
while not candidates and time.monotonic() < poll_deadline:
    sleep_for = min(POLL_SECONDS, max(0.0, poll_deadline - time.monotonic()))
    if sleep_for <= 0:
        break
    time.sleep(sleep_for)
    candidates = recent_reports()


def filter_fields(mapping, allowed_keys):
    if not isinstance(mapping, dict):
        return None
    filtered = {key: mapping[key] for key in allowed_keys if mapping.get(key) not in (None, "", {}, [])}
    return filtered or None


def show(label, value):
    if value not in (None, "", {}, []):
        print("%s: %s" % (label, json.dumps(value, ensure_ascii=False, sort_keys=True)))


def format_source_location(source_file, source_line):
    name = os.path.basename(str(source_file).strip())
    if not name:
        return ""
    line = source_line if source_line not in (None, "") else "?"
    return "  (%s:%s)" % (name, line)


def sanitize_atos_line(text):
    return ABS_SOURCE_LOC_RE.sub(lambda match: "(%s%s)" % (match.group(1), match.group(2) or ""), text)


def atos_frame(binary, base, address):
    budget = remaining_budget()
    if budget < 1.0:
        return "skipped (diagnosis budget exhausted)"
    if not binary or not os.path.exists(binary):
        return "binary not on disk"
    try:
        result = subprocess.run(
            ["atos", "-o", binary, "-l", to_hex(base), to_hex(address)],
            capture_output=True,
            text=True,
            timeout=min(ATOS_PER_CALL_CAP_SECONDS, budget),
        )
    except Exception as error:  # atos missing or timed out: keep the raw frame
        return "atos failed (%s)" % type(error).__name__
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return sanitize_atos_line(lines[0]) if lines else "atos produced no symbol"


def dump_ips(path, header, body):
    proc_name = str(header.get("app_name") or body.get("procName") or "")
    print("--- %s" % os.path.basename(path))
    print(
        "report: %s pid=%s parentPid=%s bug_type=%s timestamp=%s"
        % (
            proc_name,
            body.get("pid", header.get("pid")),
            body.get("parentPid", header.get("parentPid")),
            header.get("bug_type"),
            header.get("timestamp"),
        )
    )
    show("exception", filter_fields(body.get("exception"), ("type", "signal", "subtype")))
    show("termination", filter_fields(body.get("termination"), ("namespace", "code", "indicator")))

    images = body.get("usedImages") or body.get("images") or []
    threads = body.get("threads") or []
    faulting = body.get("faultingThread")
    if not isinstance(faulting, int) or not 0 <= faulting < len(threads):
        faulting = next((index for index, thread in enumerate(threads) if thread.get("triggered")), None)
    if faulting is None:
        print("no faulting thread recorded")
        return True
    frames = threads[faulting].get("frames") or []
    print("faulting thread %s: %d frames" % (faulting, len(frames)))
    for depth, frame in enumerate(frames):
        index = frame.get("imageIndex")
        image = images[index] if isinstance(index, int) and 0 <= index < len(images) else {}
        module = image.get("name") or "?"
        symbol = frame.get("symbol") or "<no symbol>"
        if isinstance(frame.get("symbolLocation"), int):
            symbol = "%s + %d" % (symbol, frame["symbolLocation"])
        source = ""
        if frame.get("sourceFile"):
            source = format_source_location(frame["sourceFile"], frame.get("sourceLine"))
        print("  #%-2d %-24s %s%s" % (depth, module, symbol, source))
        if source or not any(token in module for token in SYMBOLIZE_IMAGES):
            continue
        base = to_int(image.get("base"))
        offset = to_int(frame.get("imageOffset"))
        if base is None or offset is None:
            continue
        print("      atos: %s" % atos_frame(image.get("path") or "", base, base + offset))
    return True


dumped = 0
for _, path, header, body in candidates:
    if dumped >= MAX_REPORTS:
        break
    if remaining_budget() <= 0:
        print("diagnosis budget (%.0fs) exhausted" % TOTAL_BUDGET_SECONDS)
        break
    try:
        if dump_ips(path, header, body):
            dumped += 1
    except Exception as error:  # never let diagnosis change the step verdict
        print("could not read %s (%s)" % (os.path.basename(path), type(error).__name__))

if dumped == 0:
    print("no matching test-process .ips report created after epoch %.0f" % min_epoch)
PY
    echo "=== end of macOS crash reports"
}

# ---------------------------------------------------------------------------------------------
# 解析、判定与「失败用例只重跑一次」的流程在 scripts/lib/swift_test_retry.sh，与 Linux 的
# scripts/linux-check/run.sh 共用同一份实现。这里只保留 macOS 自己的两件事：跑一次 `swift test`
# 的 pty/行缓冲前缀与 stall 采样，以及崩溃时的 `.ips` 报告 dump。
# scripts/test_ci_swift_test.sh sources this file and drives it with fixture logs.
# ---------------------------------------------------------------------------------------------

# shellcheck source=scripts/lib/swift_test_retry.sh
. "$ROOT_DIR/scripts/lib/swift_test_retry.sh"

# A pty keeps stdout line-buffered (BSD `script`: the command is the rest of the argv).
SWIFT_TEST_LAUNCH_CMD="script -q /dev/null"
SWIFT_TEST_SAMPLE_FN="sample_stalled_test_processes"

sample_stalled_test_processes() {
    local pid
    for pid in $(pgrep -f swiftpm-testing || true); do
        echo "=== sample ${pid}"
        sample "$pid" 5 -mayDie 2>/dev/null || true
    done
}

# A flake is reported as a passing job with a warning, so the fix stays visible. Everything else
# keeps the original verdict and the original error lines.
main() {
    ALL_PID_FILES=""
    trap 'for f in $ALL_PID_FILES; do rm -f "$f" "$f.tmp"; done' EXIT
    local retry_enabled first_log
    retry_enabled="$(swift_test_retry_enabled)"
    first_log="$(mktemp "${TMPDIR:-/tmp}/swift-test.XXXXXX")"
    run_with_watchdog "$first_log" "$@"
    local first_exit="$RUN_EXIT" first_stalled="$RUN_STALLED" first_pids="$RUN_PIDS" first_started="$RUN_STARTED"
    echo "=== swift test process exit: ${first_exit} (stalled=${first_stalled})"

    # A crash in a later test binary must fail even if an earlier target printed a passing summary.
    if log_has_crash "$first_log"; then
        echo "::error::swift test crashed during execution"
        # The runner goes away with the job: dump filtered crash fields before failing.
        dump_macos_crash_reports "$first_started" "$first_pids" || true
        return 1
    fi

    # Read the summary before treating a stall as failure. The macos-26 exit hang writes a passing
    # summary and then stays alive, so the watchdog sets stalled on a suite that already passed.
    if [ "$(swift_test_summary_verdict "$first_log")" = "pass" ]; then
        if [ "$first_stalled" -eq 1 ] || [ "$first_exit" -ne 0 ]; then
            echo "::warning::the suite passed but swift test did not exit cleanly (exit ${first_exit}, stalled=${first_stalled}); accepting the passing summary"
        fi
        return 0
    fi

    # Swift Testing's own summary failed. Rerunning only the failing cases separates a flake from a
    # real break in one job instead of one manual `gh run rerun --failed` per red push.
    if retry_failed_cases "$first_log" "$retry_enabled" "$first_stalled" "$ROOT_DIR" "$@"; then
        return 0
    fi

    if [ "$first_stalled" -eq 1 ]; then
        echo "::error::swift test produced no output for ${SWIFT_TEST_STALL_SECONDS:-300}s; the test process is deadlocked"
        return 1
    fi
    echo "::error::swift test produced no passing summary"
    return 1
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
    exit $?
fi
