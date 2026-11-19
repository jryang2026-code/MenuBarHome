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
# A crash additionally dumps the macOS `ReportCrash` report for the test process, with the faulting
# thread's frames symbolized through `atos`: the runner is destroyed with the job, so the abort
# reason (`asi`) and its stack are only readable inside the step that saw the crash.
#
# Usage:
#   bash scripts/ci_swift_test.sh [swift test arguments...]
set -uo pipefail

# Prints the newest macOS crash reports for a crashing test process.
#
# `swift test` aborts with `signal code 6: freed pointer was not the last allocation` — a Swift
# runtime / libmalloc assertion whose only evidence is the `asi` string and the faulting stack in
# the `.ips` file ReportCrash writes just after the abort. Without this the job log ends at the
# signal line and every later diagnosis is a guess. Diagnosis must never change the step verdict:
# every command is best-effort and every failure prints a warning instead of a non-zero status.
dump_macos_crash_reports() {
    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    echo "=== macOS crash reports (ReportCrash)"
    # ReportCrash flushes asynchronously; give it a moment to land the `.ips` on disk.
    sleep 3 || true
    CRASH_REPORT_SEARCH_DIRS="$(printf '%s\n%s\n' "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")" \
        python3 - <<'PY' || echo "::warning::could not read the macOS crash reports (see the log above)"
import glob
import json
import os
import subprocess
import time

# The directories also hold months of unrelated crashes; only this run's reports are interesting.
WINDOW_SECONDS = 600
NAME_PATTERNS = ("*swiftpm-testing*", "*MenuBarMijia*", "*xctest*")
EXTENSIONS = (".ips", ".crash")
MAX_REPORTS = 2
# Only our own modules are worth an `atos` call: system frames keep the symbols ReportCrash recorded.
SYMBOLIZE_IMAGES = ("MenuBarMijiaPackageTests", "MijiaCore", "MenuBarMijiaApp")

now = time.time()
search_dirs = [line for line in os.environ.get("CRASH_REPORT_SEARCH_DIRS", "").splitlines() if line]
candidates = []
for directory in search_dirs:
    for pattern in NAME_PATTERNS:
        for extension in EXTENSIONS:
            for path in glob.glob(os.path.join(directory, pattern + extension)):
                try:
                    modified = os.path.getmtime(path)
                except OSError:
                    continue
                if now - modified <= WINDOW_SECONDS:
                    candidates.append((modified, path))
candidates.sort(reverse=True)


def to_int(value):
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        return None


def to_hex(value):
    number = to_int(value)
    return "0x%x" % number if number is not None else str(value)


def show(label, value):
    if value not in (None, "", {}, []):
        print("%s: %s" % (label, json.dumps(value, ensure_ascii=False, sort_keys=True)))


def atos_frame(binary, base, address):
    if not binary or not os.path.exists(binary):
        return "binary not on disk (%s)" % (binary or "no path in report")
    try:
        result = subprocess.run(
            ["atos", "-o", binary, "-l", to_hex(base), to_hex(address)],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as error:  # atos missing or hung: keep the raw frame
        return "atos failed (%s)" % error
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[0] if lines else "atos produced no symbol"


def dump_ips(path):
    print("--- %s" % path)
    with open(path, "r", errors="replace") as handle:
        lines = handle.read().splitlines()
    # An `.ips` is two JSON documents: a one-line header, then the report body.
    try:
        header = json.loads(lines[0]) if lines else {}
        body = json.loads("\n".join(lines[1:])) if len(lines) > 1 else {}
    except ValueError:
        print("(json decode failed, raw report follows)")
        print("\n".join(lines[:200]))
        return
    print(
        "report: %s bug_type=%s timestamp=%s"
        % (
            header.get("app_name") or body.get("procName") or "?",
            header.get("bug_type"),
            header.get("timestamp"),
        )
    )
    show("exception", body.get("exception"))
    show("termination", body.get("termination"))
    # Application Specific Information is where the abort reason lives: the Swift runtime's
    # "freed pointer was not the last allocation" and libmalloc's own diagnostics both land here.
    show("asi", body.get("asi"))

    images = body.get("usedImages") or body.get("images") or []
    threads = body.get("threads") or []
    faulting = body.get("faultingThread")
    if not isinstance(faulting, int) or not 0 <= faulting < len(threads):
        faulting = next((index for index, thread in enumerate(threads) if thread.get("triggered")), None)
    if faulting is None:
        print("no faulting thread recorded")
        return
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


def dump_text_report(path):
    print("--- %s (text report)" % path)
    with open(path, "r", errors="replace") as handle:
        for number, line in enumerate(handle):
            if number >= 200:
                break
            print(line.rstrip("\n"))


if not candidates:
    print("no report modified in the last %ds under %s" % (WINDOW_SECONDS, ", ".join(search_dirs)))
for _, path in candidates[:MAX_REPORTS]:
    try:
        if path.endswith(".ips"):
            dump_ips(path)
        else:
            dump_text_report(path)
    except Exception as error:  # never let diagnosis change the step verdict
        print("could not read %s (%s)" % (path, error))
PY
    echo "=== end of macOS crash reports"
}

evaluate_swift_test_log() {
    local log_file="$1"
    local run_exit="$2"
    local run_stalled="$3"
    local stall_limit="$4"

    # A crash in a later test binary must fail even if an earlier target printed a passing summary.
    if grep -qE 'unexpected signal code|Fatal error:' "$log_file"; then
        echo "::error::swift test crashed during execution"
        # The runner goes away with the job: dump the crash report before failing.
        dump_macos_crash_reports || true
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
evaluate_swift_test_log "$log" "$exit_code" "$stall_detected" "$stall_seconds"
exit $?
