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
# Usage:
#   bash scripts/ci_swift_test.sh [swift test arguments...]
set -uo pipefail

# Prints filtered crash metadata from newest macOS `.ips` reports written for this test run's
# process (`swiftpm-testing-helper` / `xctest`) after `run_started_epoch`.
#
# Diagnosis is bounded by a single total deadline and must never change the step verdict: every
# command is best-effort and every failure prints a warning instead of a non-zero status.
dump_macos_crash_reports() {
    local min_epoch="${1:-0}"
    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    echo "=== macOS crash reports (ReportCrash)"
    CRASH_REPORT_MIN_EPOCH="$min_epoch" \
    CRASH_REPORT_SEARCH_DIRS="${CRASH_REPORT_SEARCH_DIRS:-$(printf '%s\n%s\n' "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")}" \
        python3 - <<'PY' || echo "::warning::could not read the macOS crash reports (see the log above)"
import glob
import json
import os
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

search_dirs = [line for line in os.environ.get("CRASH_REPORT_SEARCH_DIRS", "").splitlines() if line]
try:
    min_epoch = float(os.environ.get("CRASH_REPORT_MIN_EPOCH", "0"))
except ValueError:
    min_epoch = 0.0

total_deadline = time.monotonic() + TOTAL_BUDGET_SECONDS


def remaining_budget():
    return max(0.0, total_deadline - time.monotonic())


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
                if modified >= cutoff:
                    found.append((modified, path))
    found.sort(reverse=True)
    return found


poll_deadline = min(total_deadline, time.monotonic() + REPORT_WAIT_SECONDS)
candidates = recent_reports()
while not candidates and time.monotonic() < poll_deadline:
    sleep_for = min(POLL_SECONDS, max(0.0, poll_deadline - time.monotonic()))
    if sleep_for <= 0:
        break
    time.sleep(sleep_for)
    candidates = recent_reports()


def to_int(value):
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        return None


def to_hex(value):
    number = to_int(value)
    return "0x%x" % number if number is not None else str(value)


def filter_fields(mapping, allowed_keys):
    if not isinstance(mapping, dict):
        return None
    filtered = {key: mapping[key] for key in allowed_keys if mapping.get(key) not in (None, "", {}, [])}
    return filtered or None


def show(label, value):
    if value not in (None, "", {}, []):
        print("%s: %s" % (label, json.dumps(value, ensure_ascii=False, sort_keys=True)))


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
    return lines[0] if lines else "atos produced no symbol"


def dump_ips(path):
    with open(path, "r", errors="replace") as handle:
        lines = handle.read().splitlines()
    # An `.ips` is two JSON documents: a one-line header, then the report body.
    try:
        header = json.loads(lines[0]) if lines else {}
        body = json.loads("\n".join(lines[1:])) if len(lines) > 1 else {}
    except ValueError:
        print("--- %s (json decode failed; skipping raw report)" % os.path.basename(path))
        return False
    proc_name = str(header.get("app_name") or body.get("procName") or "")
    if proc_name not in ALLOWED_PROC_NAMES:
        return False
    print("--- %s" % os.path.basename(path))
    print(
        "report: %s bug_type=%s timestamp=%s"
        % (
            proc_name,
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
            source = "  (%s:%s)" % (frame["sourceFile"], frame.get("sourceLine", "?"))
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
for _, path in candidates:
    if dumped >= MAX_REPORTS:
        break
    if remaining_budget() <= 0:
        print("diagnosis budget (%.0fs) exhausted" % TOTAL_BUDGET_SECONDS)
        break
    try:
        if dump_ips(path):
            dumped += 1
    except Exception as error:  # never let diagnosis change the step verdict
        print("could not read %s (%s)" % (os.path.basename(path), type(error).__name__))

if dumped == 0:
    print("no matching test-process .ips report created after epoch %.0f" % min_epoch)
PY
    echo "=== end of macOS crash reports"
}

evaluate_swift_test_log() {
    local log_file="$1"
    local run_exit="$2"
    local run_stalled="$3"
    local stall_limit="$4"
    local run_started_epoch="${5:-0}"

    # A crash in a later test binary must fail even if an earlier target printed a passing summary.
    if grep -qE 'unexpected signal code|Fatal error:' "$log_file"; then
        echo "::error::swift test crashed during execution"
        # The runner goes away with the job: dump filtered crash fields before failing.
        dump_macos_crash_reports "$run_started_epoch" || true
        return 1
    fi

    # Every Swift Testing target summary must pass, no test issue may be recorded in any target,
    # and no subsequent target (`Test run started.`) may hang before printing its own summary.
    local summary_verdict
    summary_verdict="$(awk '
        /(^|◇ )Test run started\./ { pending_target = 1; next }
        /Test run with [0-9]+ tests? in [0-9]+ suites?/ {
            summaries++
            pending_target = 0
            if ($0 !~ /Test run with [0-9]+ tests? in [0-9]+ suites? passed/) {
                failed = 1
            }
            next
        }
        /✘ Test |recorded an issue/ { failed = 1 }
        END {
            print (summaries > 0 && !failed && !pending_target) ? "pass" : "fail"
        }
    ' "$log_file")"

    if [ "$summary_verdict" = "pass" ]; then
        if [ "$run_stalled" -eq 1 ] || [ "$run_exit" -ne 0 ]; then
            echo "::warning::the suite passed but swift test did not exit cleanly (exit ${run_exit}, stalled=${run_stalled}); accepting the passing summary"
        fi
        return 0
    fi
    if [ "$run_stalled" -eq 1 ]; then
        echo "::error::swift test produced no output for ${stall_limit}s; the test process is deadlocked"
        return 1
    fi
    echo "::error::swift test produced no passing summary"
    return 1
}

stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
tick=10
log="$(mktemp -t swift-test)"
echo "swift test log: $log"
run_started_epoch="$(date +%s)"

# A pty keeps stdout line-buffered: without it the final summary can sit in a 4 KiB buffer
# forever when the process hangs at exit, and the watchdog would never see the result.
script -q /dev/null swift test "$@" >"$log" 2>&1 &
test_pid=$!
# Stream the log into the job output so a killed job still leaves the last test visible.
tail -n +1 -f "$log" &
tail_pid=$!

sample_process() {
    for pid in $(pgrep -f swiftpm-testing || true); do
        echo "=== sample ${pid}"
        sample "$pid" 5 -mayDie 2>/dev/null || true
    done
}

stalled=0
last_size=-1
stall_detected=0
while kill -0 "$test_pid" 2>/dev/null; do
    sleep "$tick"
    size="$(wc -c <"$log" | tr -d ' ')"
    if [ "$size" = "$last_size" ]; then
        stalled=$((stalled + tick))
    else
        stalled=0
        last_size="$size"
    fi
    if [ "$stalled" -ge "$stall_seconds" ]; then
        sample_process
        kill -TERM "$test_pid" 2>/dev/null || true
        sleep 2
        pkill -TERM -f swiftpm-testing 2>/dev/null || true
        sleep 2
        pkill -KILL -f swiftpm-testing 2>/dev/null || true
        stall_detected=1
        break
    fi
done
wait "$test_pid" 2>/dev/null
exit_code=$?
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true

echo "=== swift test process exit: $exit_code (stalled=${stall_detected})"
# Read the summary before treating a stall as failure. The macos-26 exit hang writes a passing
# summary and then stays alive, so the watchdog sets stall_detected on a suite that already passed.
evaluate_swift_test_log "$log" "$exit_code" "$stall_detected" "$stall_seconds" "$run_started_epoch"
exit $?
